/*
   Copyright (C) 2011 Free Software Foundation, Inc.

   Author: Eric Wasylishen <ewasylishen@gmail.com>

   This file is part of GNUstep.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; see the file COPYING.LIB.
   If not, see <http://www.gnu.org/licenses/> or write to the 
   Free Software Foundation, 51 Franklin Street, Fifth Floor, 
   Boston, MA 02110-1301, USA.
*/

#include "config.h"
#include "x11/XGServer.h"
#include "x11/XGServerWindow.h"
#include "cairo/XGCairoModernSurface.h"
#include <cairo-xlib.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#define GSWINDEVICE ((gswindow_device_t *)gsDevice)

/*
 * The visible part of a window with a shadow margin: the surface less the
 * margin, with rounded corners.
 */
static void
visible_path(cairo_t *cr, int width, int height, const int *margin, double radius)
{
  double x0 = margin[0], x1 = width - margin[1];
  double y0 = margin[2], y1 = height - margin[3];

  cairo_new_sub_path(cr);
  cairo_arc(cr, x1 - radius, y0 + radius, radius, -M_PI / 2, 0);
  cairo_arc(cr, x1 - radius, y1 - radius, radius, 0, M_PI / 2);
  cairo_arc(cr, x0 + radius, y1 - radius, radius, M_PI / 2, M_PI);
  cairo_arc(cr, x0 + radius, y0 + radius, radius, M_PI, 3 * M_PI / 2);
  cairo_close_path(cr);
}

/*
 * The shadow's opacity at a point outside the rounded visible part, as
 * GNOME's windows have it (libadwaita 1.7 measured under Mutter): black,
 * from 0.19 at the edge to about 0.01 thirty pixels out at the sides;
 * weaker and shorter above and a little stronger below, as the shadow sits
 * lower; following the rounded corners. 0 inside.
 */
static double
shadow_alpha(double px, double py, double x0, double x1, double y0, double y1,
	     double radius, double scale)
{
  double dx, dy, corner, d, vertical, side;

  /* Distance outside the rounded visible part, and how much of it is
     vertical. */
  dx = MAX(MAX(x0 + radius - px, px - (x1 - radius)), 0.0);
  dy = MAX(MAX(y0 + radius - py, py - (y1 - radius)), 0.0);
  corner = sqrt(dx * dx + dy * dy);
  if (corner <= radius && px > x0 && px < x1 && py > y0 && py < y1)
    {
      return 0.0;
    }
  /* The fall-off lengths are GNOME's at scale 1. */
  d = MAX(corner - radius, 0.0) / scale;
  vertical = corner > 0.0 ? dy / corner : 0.0;
  side = 0.19 * exp(-d / 10.0);
  if (py < y0 + radius)
    {
      return (1.0 - vertical) * side + vertical * 0.10 * exp(-d / 3.5);
    }
  if (py > y1 - radius)
    {
      return (1.0 - vertical) * side + vertical * 0.21 * exp(-d / 11.0);
    }
  return side;
}

/*
 * One layer of a CSS box-shadow round a rounded box: the box grown by
 * `spread` (its corner radius too) and moved down by `offset`, blurred by
 * `blur` (a Gaussian with half that as its deviation), as seen at (px, py).
 * Computed from the distance to the grown box's rounded outline, so it
 * follows the corners as a browser's does.
 */
static double
box_shadow_layer(double px, double py, double x0, double x1, double y0,
		 double y1, double radius, double offset, double spread,
		 double blur)
{
  double r = radius + spread;
  double left = x0 - spread, right = x1 + spread;
  double top = y0 - spread + offset, bottom = y1 + spread + offset;
  double qx = MAX(MAX(left + r - px, px - (right - r)), 0.0);
  double qy = MAX(MAX(top + r - py, py - (bottom - r)), 0.0);
  double d = sqrt(qx * qx + qy * qy) - r;

  return 0.5 * erfc(d / (blur / 2.0 * M_SQRT2));
}

/*
 * A popover's shadow (libadwaita's popover contents): box-shadow
 * 0 1px 5px 1px black at 0.09, and 0 2px 14px 3px black at 0.05, at
 * scale 1, round its rounded corners. 0 inside the rounded visible part.
 */
static double
popover_shadow_alpha(double px, double py, double x0, double x1, double y0,
		     double y1, double radius, double scale)
{
  double dx = MAX(MAX(x0 + radius - px, px - (x1 - radius)), 0.0);
  double dy = MAX(MAX(y0 + radius - py, py - (y1 - radius)), 0.0);

  if (sqrt(dx * dx + dy * dy) <= radius && px > x0 && px < x1 && py > y0 && py < y1)
    {
      return 0.0;
    }
  return 0.09 * box_shadow_layer(px, py, x0, x1, y0, y1, radius,
				 1 * scale, 1 * scale, 5 * scale)
    + 0.05 * box_shadow_layer(px, py, x0, x1, y0, y1, radius,
			      2 * scale, 3 * scale, 14 * scale);
}

static inline uint32_t
shadow_pixel(double alpha)
{
  /* Premultiplied black. */
  return ((uint32_t)(alpha * 255.0 + 0.5)) << 24;
}

/*
 * The shadow of a small window with the given margin and radius: its four
 * corners, and between them straight edges SHADOW_TILE pixels long, on a
 * surface like the window's. Computed once and kept in the X server; any
 * window's shadow is put together from it there (see create_shadow).
 */
#define SHADOW_TILE 64

/* A template kept in the X server, and what it was made for. */
typedef struct {
  cairo_surface_t *surface;
  Display *display;
  int margin[4];
  int radius;
  double scale;
} shadow_cache;

static cairo_surface_t *
shadow_template(cairo_surface_t *similar, const int *margin, int radius,
		double scale, BOOL popover)
{
  /* One for windows, one for popovers. */
  static shadow_cache caches[2];
  shadow_cache *cache = &caches[popover ? 1 : 0];
  int width = margin[0] + 2 * radius + SHADOW_TILE + margin[1];
  int height = margin[2] + 2 * radius + SHADOW_TILE + margin[3];
  double x0 = margin[0], x1 = width - margin[1];
  double y0 = margin[2], y1 = height - margin[3];
  Display *display = cairo_xlib_surface_get_display(similar);
  cairo_surface_t *image;
  cairo_t *cr;
  unsigned char *data;
  int stride, x, y;

  if (cache->surface != NULL && cache->display == display
    && cache->radius == radius && cache->scale == scale
    && memcmp(cache->margin, margin, sizeof(cache->margin)) == 0)
    {
      return cache->surface;
    }
  image = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
  if (cairo_surface_status(image) != CAIRO_STATUS_SUCCESS)
    {
      cairo_surface_destroy(image);
      return NULL;
    }
  cairo_surface_flush(image);
  data = cairo_image_surface_get_data(image);
  stride = cairo_image_surface_get_stride(image);
  for (y = 0; y < height; y++)
    {
      uint32_t *row = (uint32_t *)(data + y * stride);

      for (x = 0; x < width; x++)
	{
	  row[x] = shadow_pixel(popover
	    ? popover_shadow_alpha(x + 0.5, y + 0.5, x0, x1, y0, y1, radius, scale)
	    : shadow_alpha(x + 0.5, y + 0.5, x0, x1, y0, y1, radius, scale));
	}
    }
  cairo_surface_mark_dirty(image);
  if (cache->surface != NULL)
    {
      cairo_surface_destroy(cache->surface);
    }
  cache->surface = cairo_surface_create_similar(similar,
    CAIRO_CONTENT_COLOR_ALPHA, width, height);
  cr = cairo_create(cache->surface);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_surface(cr, image, 0, 0);
  cairo_paint(cr);
  cairo_destroy(cr);
  cairo_surface_destroy(image);
  cache->display = display;
  memcpy(cache->margin, margin, sizeof(cache->margin));
  cache->radius = radius;
  cache->scale = scale;
  return cache->surface;
}

/* Copies a rectangle of the template to (dx, dy) in the shadow. */
static void
shadow_copy(cairo_t *cr, cairo_surface_t *template, double sx, double sy,
	    double w, double h, double dx, double dy)
{
  if (w <= 0 || h <= 0)
    {
      return;
    }
  cairo_save(cr);
  cairo_rectangle(cr, dx, dy, w, h);
  cairo_clip(cr);
  cairo_set_source_surface(cr, template, dx - sx, dy - sy);
  cairo_paint(cr);
  cairo_restore(cr);
}

/*
 * The shadow round a window with a shadow margin, on a surface like the
 * window's (so exposes copy it within the X server), transparent inside the
 * visible part: the template's corners, and its straight edges repeated
 * along the window's (the shadow there only depends on the distance from
 * the edge). All copies within the X server: windows are resized often,
 * and a new shadow is made at each size.
 */
static cairo_surface_t *
create_shadow(cairo_surface_t *similar, int width, int height,
	      const int *margin, int radius, double scale, BOOL popover)
{
  int l = margin[0], r = margin[1], t = margin[2], b = margin[3];
  cairo_surface_t *template, *shadow;
  int tw, th, x, y;
  cairo_t *cr;

  if (width <= 0 || height <= 0 || width - l - r < 2 * radius
    || height - t - b < 2 * radius)
    {
      return NULL;
    }
  template = shadow_template(similar, margin, radius, scale, popover);
  if (template == NULL)
    {
      return NULL;
    }
  tw = l + 2 * radius + SHADOW_TILE + r;
  th = t + 2 * radius + SHADOW_TILE + b;
  /* Similar surfaces start transparent. */
  shadow = cairo_surface_create_similar(similar, CAIRO_CONTENT_COLOR_ALPHA,
					width, height);
  cr = cairo_create(shadow);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  /* Corners: the margin and the radius each way. */
  shadow_copy(cr, template, 0, 0, l + radius, t + radius, 0, 0);
  shadow_copy(cr, template, tw - r - radius, 0, r + radius, t + radius,
	      width - r - radius, 0);
  shadow_copy(cr, template, 0, th - b - radius, l + radius, b + radius,
	      0, height - b - radius);
  shadow_copy(cr, template, tw - r - radius, th - b - radius, r + radius,
	      b + radius, width - r - radius, height - b - radius);
  /* Edges between them, a tile at a time. */
  for (x = l + radius; x < width - r - radius; x += SHADOW_TILE)
    {
      int w = MIN(SHADOW_TILE, width - r - radius - x);

      shadow_copy(cr, template, l + radius, 0, w, t, x, 0);
      shadow_copy(cr, template, l + radius, th - b, w, b, x, height - b);
    }
  for (y = t + radius; y < height - b - radius; y += SHADOW_TILE)
    {
      int h = MIN(SHADOW_TILE, height - b - radius - y);

      shadow_copy(cr, template, 0, t + radius, l, h, 0, y);
      shadow_copy(cr, template, tw - r, t + radius, r, h, width - r, y);
    }
  cairo_destroy(cr);
  return shadow;
}

@implementation XGCairoModernSurface

- (id) initWithDevice: (void *)device
{
  cairo_surface_t *windowsurface;

  gsDevice = device;

  // Create a cairo xlib surface for the window
  {
    Display *dpy = GSWINDEVICE->display;
    Visual *visual;
    XWindowAttributes attributes;
    
    if (!XGetWindowAttributes(dpy, GSWINDEVICE->ident, &attributes))
      {
	visual = DefaultVisual(dpy, DefaultScreen(dpy));
      }
    else
      {
	visual = attributes.visual;
      }
    
    windowsurface = cairo_xlib_surface_create(GSWINDEVICE->display,
					      GSWINDEVICE->ident,
					      visual,
					      GSWINDEVICE->xframe.size.width,
					      GSWINDEVICE->xframe.size.height);
  }


  if (GSWINDEVICE->type == NSBackingStoreNonretained)
    {
      // Don't double-buffer:
      // use the window surface as the drawing destination.

      _surface = windowsurface;
    }
  else
    {
      // Do double-buffer:
      // Create a similar surface to the window which supports alpha

      // Ask XGServerWindow to call +[CairoContext handleExposeRect:forDriver:]
      // to let us handle the back buffer -> front buffer copy using cairo.
      GSWINDEVICE->gdriverProtocol |= GDriverHandlesExpose | GDriverHandlesBacking;
      /* A surface the window had before (the window changed size, say) may
	 outlive the window: it no longer touches the window device. */
      if (GSWINDEVICE->gdriver != NULL && GSWINDEVICE->gdriver != self
	&& [(id)GSWINDEVICE->gdriver isKindOfClass: [XGCairoModernSurface class]])
	{
	  ((XGCairoModernSurface *)GSWINDEVICE->gdriver)->_isDriver = NO;
	}
      GSWINDEVICE->gdriver = self;
      _isDriver = YES;

      _windowSurface = windowsurface;
      _surface = cairo_surface_create_similar(windowsurface,
					      CAIRO_CONTENT_COLOR_ALPHA,
					      GSWINDEVICE->xframe.size.width,
					      GSWINDEVICE->xframe.size.height);
      if (GSWINDEVICE->shadow[0] || GSWINDEVICE->shadow[1]
	|| GSWINDEVICE->shadow[2] || GSWINDEVICE->shadow[3])
	{
	  _shadowSurface = create_shadow(windowsurface,
					 GSWINDEVICE->xframe.size.width,
					 GSWINDEVICE->xframe.size.height,
					 GSWINDEVICE->shadow,
					 GSWINDEVICE->corner_radius,
					 GSWINDEVICE->shadow_scale,
					 GSWINDEVICE->shadow_popover);
	}

      /*NSLog(@"Window surface type %d, back buffer type %d, w %d h %d",
	(int) cairo_surface_get_type(_windowSurface),
	(int) cairo_surface_get_type(_surface),
	(int) GSWINDEVICE->xframe.size.width,
	(int) GSWINDEVICE->xframe.size.height);
      */
    }
  
  return self;
}

/* The X window is about to go.  cairo frees the Render Picture it made for
 * the window when the surface is finished, which would otherwise happen at
 * some later autorelease pool drain: after XDestroyWindow, which has already
 * freed the Picture, so the X server answers with RenderBadPicture.  The back
 * buffer and the shadow are pixmaps of their own and can wait. */
- (void) windowWillTerminate
{
  /* The window device goes with the window. */
  _isDriver = NO;
  if (_windowSurface != NULL)
    {
      cairo_surface_destroy(_windowSurface);
      _windowSurface = NULL;
    }
}

- (void) dealloc
{
  /* The window holds the gdriver without retaining it, and -termwindow:
     sends it -windowWillTerminate.  The gui lets go of the window's
     graphics state, and so of this surface, before it terminates the
     window, so a surface nothing else holds is freed first: then the
     window must not name it. */
  if (_isDriver && GSWINDEVICE->gdriver == self)
    {
      GSWINDEVICE->gdriver = NULL;
    }
  if (_windowSurface != NULL)
    {
      cairo_surface_destroy(_windowSurface);
    }
  if (_shadowSurface != NULL)
    {
      cairo_surface_destroy(_shadowSurface);
    }
  [super dealloc];
}

- (NSSize) size
{
  return GSWINDEVICE->xframe.size;
}

- (void) handleExposeRect: (NSRect)rect
{
  cairo_t *windowCtx;

  if (_windowSurface == NULL)
    {
      return;
    }
  windowCtx = cairo_create(_windowSurface);

  double backupOffsetX, backupOffsetY;

  // Temporairly cancel the device offset on the back buffer since
  // we want to work with raw X11 pixel coordinates

  cairo_surface_get_device_offset(_surface, &backupOffsetX, &backupOffsetY);
  cairo_surface_set_device_offset(_surface, 0, 0);

  // Copy the desired rectangle from the back buffer to the
  // front buffer

  // FIXME: should round
  cairo_rectangle(windowCtx, rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
  cairo_clip(windowCtx);
  cairo_set_operator(windowCtx, CAIRO_OPERATOR_SOURCE);
  if (_shadowSurface != NULL)
    {
      /* The window's contents inside its rounded visible part, the
	 shadow everywhere else (the margin and the corners). Rectangles
	 copy within the X server; only the four corners take the rounded
	 clip, so nothing the gui draws can un-round them. */
      int width = GSWINDEVICE->xframe.size.width;
      int height = GSWINDEVICE->xframe.size.height;
      int x0 = GSWINDEVICE->shadow[0], x1 = width - GSWINDEVICE->shadow[1];
      int y0 = GSWINDEVICE->shadow[2], y1 = height - GSWINDEVICE->shadow[3];
      int r = GSWINDEVICE->corner_radius;
      int corners[4][2] = { { x0, y0 }, { x1 - r, y0 }, { x0, y1 - r }, { x1 - r, y1 - r } };
      int i;

      cairo_save(windowCtx);
      cairo_rectangle(windowCtx, x0, y0 + r, x1 - x0, (y1 - r) - (y0 + r));
      cairo_rectangle(windowCtx, x0 + r, y0, (x1 - r) - (x0 + r), r);
      cairo_rectangle(windowCtx, x0 + r, y1 - r, (x1 - r) - (x0 + r), r);
      cairo_clip(windowCtx);
      cairo_set_source_surface(windowCtx, _surface, 0, 0);
      cairo_paint(windowCtx);
      cairo_restore(windowCtx);

      cairo_save(windowCtx);
      cairo_rectangle(windowCtx, 0, 0, width, y0);
      cairo_rectangle(windowCtx, 0, y1, width, height - y1);
      cairo_rectangle(windowCtx, 0, y0, x0, y1 - y0);
      cairo_rectangle(windowCtx, x1, y0, width - x1, y1 - y0);
      cairo_clip(windowCtx);
      cairo_set_source_surface(windowCtx, _shadowSurface, 0, 0);
      cairo_paint(windowCtx);
      cairo_restore(windowCtx);

      for (i = 0; r > 0 && i < 4; i++)
	{
	  NSRect square = NSMakeRect(corners[i][0], corners[i][1], r, r);

	  if (!NSIntersectsRect(square, rect))
	    {
	      continue;
	    }
	  cairo_save(windowCtx);
	  cairo_rectangle(windowCtx, corners[i][0], corners[i][1], r, r);
	  cairo_clip(windowCtx);
	  cairo_set_source_surface(windowCtx, _shadowSurface, 0, 0);
	  cairo_paint(windowCtx);
	  visible_path(windowCtx, width, height, GSWINDEVICE->shadow, r);
	  cairo_clip(windowCtx);
	  cairo_set_source_surface(windowCtx, _surface, 0, 0);
	  cairo_paint(windowCtx);
	  cairo_restore(windowCtx);
	}
    }
  else
    {
      cairo_set_source_surface(windowCtx, _surface, 0, 0);
      cairo_paint(windowCtx);
    }

  // Debugging
  // cairo_reset_clip(windowCtx);
  // cairo_set_source_rgba(windowCtx, 1.0, 0.0, 0.0, 0.5);
  // cairo_rectangle(windowCtx, rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
  // cairo_stroke(windowCtx);
  //  NSLog(@"Exposing rect %@ with cairo. Status: '%s'", NSStringFromRect(rect), cairo_status_to_string(cairo_status(windowCtx)));

  cairo_destroy(windowCtx);
  
  // Restore device offset
  cairo_surface_set_device_offset(_surface, backupOffsetX, backupOffsetY);
}

@end

