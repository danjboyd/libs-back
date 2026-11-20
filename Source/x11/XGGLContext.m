/* -*- mode:ObjC -*-
   XGGLContext - backend implementation of NSOpenGLContext

   Copyright (C) 1998,2002 Free Software Foundation, Inc.

   Written by:  Frederic De Jaeger
   Date: Nov 2002
   
   This file is part of the GNU Objective C User Interface Library.

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
#ifdef HAVE_GLX
#include <Foundation/NSDebug.h>
#include <Foundation/NSException.h>
#include <Foundation/NSDictionary.h>
#include <GNUstepGUI/GSDisplayServer.h>
#include <AppKit/NSView.h>
#include <AppKit/NSWindow.h>
#include "x11/XGServerWindow.h"
#include "x11/XGOpenGL.h"
#include <X11/Xlib.h>
#ifdef HAVE_XSHAPE
#include <X11/extensions/shape.h>
#endif

//FIXME
//should I store the display ?
#define MAKE_DISPLAY(dpy) Display *dpy;\
  dpy = [(XGServer *)GSCurrentServer() xDisplay];\
  NSAssert(dpy != NULL, NSInternalInconsistencyException)

/* The child X window an OpenGL context draws into, placed over its view in
 * the view's X window.  X draws it whatever the GNUstep views round it do,
 * so -update keeps it in step with the view: unmapped while the view or an
 * ancestor is hidden, while none of the view is visible or once the view has
 * left the window, and clipped (a bounding shape) to the view's visible
 * rectangle, as inside a scroll view.  It is created unmapped; -update maps
 * it.
 */
@interface XGXSubWindow : NSObject
{
  @public
  Window  xwindowid;
  NSView *attached;
  Display *display;
  Colormap colormap;
  int windowNumber;     /* The NSWindow the X window was made in, */
  Window parent;        /* and that window's X window.  */
  BOOL mapped;
  BOOL shaped;
}

+ subwindowOnView:(NSView *)view visualinfo:(XVisualInfo *)xVisualInfo;

- (void) update;
- (void) detach;
- (BOOL) parentExists;

@end

/* Where the rectangle R of VIEW lies in the X window of VIEW's window, in X
 * pixels (origin at the top left).  Window base coordinates are device
 * pixels, also when the window is scaled (GSScaleFactor), so the view is
 * converted to them rather than to the coordinates of another view, which
 * would be points.
 */
static XRectangle
XRectForViewRect(NSView *view, NSRect r, XGServer *server,
                 gswindow_device_t *win_info)
{
  NSRect rect = [view convertRect: r toView: nil];
  XRectangle result;

  if ([server handlesWindowDecorations] == YES)
    {
      /* The window manager handles window decorations, so the
       * parent X window is equal to the content view.
       */
      NSView *content = [[view window] contentView];
      NSRect contentRect = [content convertRect: [content bounds] toView: nil];

      rect.origin.x -= NSMinX(contentRect);
      rect.origin.y -= NSMinY(contentRect);
    }
  result.x = NSMinX(rect);
  result.y = NSHeight(win_info->xframe) - NSMaxY(rect);
  result.width = NSWidth(rect);
  result.height = NSHeight(rect);
  return result;
}

#ifdef HAVE_XSHAPE
/* Whether the display has the shape extension, which clips the window.  */
static BOOL
HasShape(Display *dpy)
{
  static Display *checked = NULL;
  static BOOL has = NO;
  int event_base, error_base;

  if (dpy != checked)
    {
      has = XShapeQueryExtension(dpy, &event_base, &error_base) ? YES : NO;
      checked = dpy;
    }
  return has;
}
#endif

static int
IgnoreXErrors(Display *dpy, XErrorEvent *event)
{
  return 0;
}

@implementation XGXSubWindow

//We assume that the current context is the same and is an XGServer
- initWithView: (NSView *)view visualinfo: (XVisualInfo *)xVisualInfo
{
  XRectangle frame;
  gswindow_device_t *win_info;
  XGServer *server;
  NSWindow *window;
  int mask;
  XSetWindowAttributes window_attributes;

  self = [super init];

  if (!self)
    {
      return nil;
    }

  window = [view window];
  NSAssert(window, @"Request of an X window attachment on a view that is not\
                     on a NSWindow");

  if ([view isRotatedFromBase])
    {
      [NSException raise: NSInvalidArgumentException
                   format: @"Cannot attach an Xwindow to a view that is\
                           rotated"];
    }
  
  server = (XGServer *)GSServerForWindow(window);
  NSAssert(server != nil, NSInternalInconsistencyException);

  NSAssert([server isKindOfClass: [XGServer class]], 
           NSInternalInconsistencyException);

  win_info = [XGServer _windowWithTag: [window windowNumber]];
  NSAssert(win_info, NSInternalInconsistencyException);

  frame = XRectForViewRect(view, [view bounds], server, win_info);

  display = win_info->display;
  colormap = XCreateColormap(display, win_info->ident,
                             xVisualInfo->visual, AllocNone);
  window_attributes.border_pixel = 0;
  window_attributes.background_pixel = 0;
  window_attributes.colormap = colormap;

  window_attributes.event_mask = StructureNotifyMask
                               | VisibilityChangeMask
                               | ExposureMask;

  mask = CWBackPixel | CWBorderPixel | CWColormap | CWEventMask;

  /* At least one pixel each way: X refuses an empty window.  */
  xwindowid = XCreateWindow(display, win_info->ident,
                            frame.x, frame.y,
                            frame.width ? frame.width : 1,
                            frame.height ? frame.height : 1, 0,
                            xVisualInfo->depth, InputOutput,
                            xVisualInfo->visual, mask, &window_attributes);

  attached = view;
  windowNumber = [window windowNumber];
  parent = win_info->ident;
  mapped = NO;
  shaped = NO;

  /* Created unmapped: -update maps it if the view is visible, clipped to
   * the part of it that is.  */
  [self update];

  return self;
}

/* Whether the X window it was made in is still there.  When the NSWindow's
 * X window is destroyed (the window is closed), the X server destroys this
 * one with it, and nothing may be asked of it any more.  */
- (BOOL) parentExists
{
  gswindow_device_t *win_info = [XGServer _windowWithTag: windowNumber];

  return win_info != NULL && win_info->ident == parent;
}

- (void) map
{
  if (xwindowid != None && !mapped)
    {
      XMapWindow(display, xwindowid);
      mapped = YES;
    }
}

- (void) unmap
{
  if (xwindowid != None && mapped)
    {
      if ([self parentExists])
        {
          XUnmapWindow(display, xwindowid);
        }
      mapped = NO;
    }
}

- (void) detach
{
  /* Once only: the context detaches explicitly, then again on dealloc.  */
  if (xwindowid != None)
    {
      if ([self parentExists])
        {
          XDestroyWindow(display, xwindowid);
        }
      xwindowid = None;
      mapped = NO;
    }
  if (colormap != None)
    {
      XFreeColormap(display, colormap);
      colormap = None;
    }
  attached = nil;
}

- (void) update
{
  XRectangle frame;
  gswindow_device_t *win_info;
  GSDisplayServer *server;
  NSWindow *win;
  NSRect visible = NSZeroRect;
  BOOL shown;

  NSAssert(attached, NSInternalInconsistencyException);
  if (xwindowid == None)
    {
      return;
    }
  if (![self parentExists])
    {
      /* Gone with the NSWindow's X window; the context attaches again.  */
      mapped = NO;
      return;
    }

  win = [attached window];
  if (win == nil || [win windowNumber] != windowNumber)
    {
      /* The view has left the window the X window is in.  The gui clears
       * the context's drawable then; until it does, keep it off screen.  */
      NSDebugMLLog(@"GLX", @"%@ left its window: unmapping %lu", attached,
                   (unsigned long)xwindowid);
      [self unmap];
      return;
    }

  NSAssert1(![attached isRotatedFromBase],
	    @"%@ is rotated, now!", attached);
  
  server = GSServerForWindow(win);
  NSAssert(server != nil, NSInternalInconsistencyException);

  NSAssert([server isKindOfClass: [XGServer class]], 
	   NSInternalInconsistencyException);

  win_info = [XGServer _windowWithTag: windowNumber];
  NSAssert(win_info, NSInternalInconsistencyException);

  frame = XRectForViewRect(attached, [attached bounds], (XGServer *)server,
                           win_info);
  XMoveResizeWindow(display, xwindowid, frame.x, frame.y,
                    frame.width ? frame.width : 1,
                    frame.height ? frame.height : 1);

  /* A child window is drawn whatever the views round it do, so it has to
   * be unmapped with the view or an ancestor, and clipped to the part of
   * the view that is visible (inside a scroll view, say).  */
  shown = ![attached isHiddenOrHasHiddenAncestor];
  if (shown)
    {
      visible = [attached visibleRect];
      shown = !NSIsEmptyRect(visible) && frame.width > 0 && frame.height > 0;
    }
  NSDebugMLLog(@"GLX", @"update %lu: frame (%d, %d, %u, %u) shown %d visible %@",
               (unsigned long)xwindowid, frame.x, frame.y,
               frame.width, frame.height, shown, NSStringFromRect(visible));
  if (!shown)
    {
      [self unmap];
      return;
    }

#ifdef HAVE_XSHAPE
  if (HasShape(display))
    {
      if (NSEqualRects(visible, [attached bounds]))
        {
          if (shaped)
            {
              XShapeCombineMask(display, xwindowid, ShapeBounding, 0, 0,
                                None, ShapeSet);
              shaped = NO;
            }
        }
      else
        {
          XRectangle clip = XRectForViewRect(attached, visible,
                                             (XGServer *)server, win_info);
          int x0 = MAX(clip.x - frame.x, 0);
          int y0 = MAX(clip.y - frame.y, 0);
          int x1 = MIN(clip.x + (int)clip.width - frame.x, (int)frame.width);
          int y1 = MIN(clip.y + (int)clip.height - frame.y, (int)frame.height);
          XRectangle box;

          if (x1 <= x0 || y1 <= y0)
            {
              /* Less than a pixel of it shows.  */
              [self unmap];
              return;
            }
          /* In the child window's own coordinates.  */
          box.x = x0;
          box.y = y0;
          box.width = x1 - x0;
          box.height = y1 - y0;
          XShapeCombineRectangles(display, xwindowid, ShapeBounding, 0, 0,
                                  &box, 1, ShapeSet, Unsorted);
          shaped = YES;
        }
    }
#endif

  [self map];
}

- (void) dealloc
{
  NSDebugMLLog(@"GLX", @"Deallocating");

  [self detach];
  [super dealloc];
}

+ subwindowOnView:(NSView *)view visualinfo:(XVisualInfo *)xVisualInfo
{
  XGXSubWindow *win = [[self alloc] initWithView: view visualinfo: xVisualInfo];

  return AUTORELEASE(win);
}

@end

//FIXME:
//should be on per thread basis.
static XGGLContext *currentGLContext;

@implementation XGGLContext

+ (void)clearCurrentContext
{
  MAKE_DISPLAY(dpy);

  if (!XGGLLoad())
    {
      return;
    }

  if ([XGGLPixelFormat glxMinorVersion] >= 3)
    {
      if (!glXMakeContextCurrent(dpy, None, None, NULL))
        {
          NSDebugMLLog(@"GLX", 
                       @"Cannot clear current GL context - Error %s",
                       glGetString(glGetError()));
        }
    }
  else
    {
      if (!glXMakeCurrent(dpy, None, NULL))
        {
          NSDebugMLLog(@"GLX", 
                       @"Can not clear current GL context - Error %s",
                       glGetString(glGetError()));
        }
    }

  currentGLContext = nil;
}

+ (NSOpenGLContext *)currentContext
{
  return currentGLContext;
}

- (void) _detach
{
  if (xSubWindow)
    {
      if (currentGLContext == self)
        {
          [XGGLContext clearCurrentContext];
        }

      if (glx_drawable != None && glx_drawable != xSubWindow->xwindowid)
        {
          MAKE_DISPLAY(dpy);

          if ([xSubWindow parentExists])
            {
              glXDestroyWindow(dpy, glx_drawable);
            }
          else
            {
              /* The X window has gone with its parent, and the server has
               * freed the GLX window with it: free libGL's side of it, and
               * ignore the server's error.  */
              XErrorHandler old;

              XSync(dpy, False);
              old = XSetErrorHandler(IgnoreXErrors);
              glXDestroyWindow(dpy, glx_drawable);
              XSync(dpy, False);
              XSetErrorHandler(old);
            }
        }
      glx_drawable = None;

      /* The X window goes now, not when the subwindow object is
       * deallocated: something may still hold it (an autorelease pool),
       * and until then the window would stay on screen over its parent.  */
      [xSubWindow detach];
      DESTROY(xSubWindow);
    }
}

/* If the X window has gone with the NSWindow's (the window was closed and
 * shown again), attach to the view again; the GLX context stays.  While the
 * window has no X window, nothing changes (the drawable stays dead, as it
 * always has, rather than -makeCurrentContext starting to raise).  */
- (void) _attachAgainIfWindowGone
{
  if (xSubWindow != nil && ![xSubWindow parentExists])
    {
      NSView *view = xSubWindow->attached;

      if (view != nil && [view window] != nil
          && [XGServer _windowWithTag: [[view window] windowNumber]] != NULL)
        {
          NSDebugMLLog(@"GLX", @"%@: X window gone, attaching again", view);
          [self setView: view];
        }
    }
}

- (GLXContext)glxcontext
{
  return glx_context;
}

- (void *)CGLContextObj
{
  // FIXME: Until we have a wrapper library
  // return the underlying context directly
  return (void*)glx_context;
}

- (void)clearDrawable
{
  [self _detach];
}

- (void)copyAttributesFromContext:(NSOpenGLContext *)context 
			 withMask:(unsigned long)mask
{
  GLenum error;
  MAKE_DISPLAY(dpy);

  if (context == nil || ![context isKindOfClass: [XGGLContext class]])
    {
        [NSException raise: NSInvalidArgumentException
		            format: @"%@ is an invalid context", context];
    }

  glXCopyContext(dpy, ((XGGLContext *)context)->glx_context, 
                 glx_context, mask);

  error = glGetError();
  if (error != GL_NO_ERROR)
    {
      NSDebugMLLog(@"GLX", 
                   @"Cannot copy GL context %@ from context %@ - Error %s",
                   self, context, glGetString(error));
    }
}

- (void)createTexture:(unsigned long)target 
	     fromView:(NSView*)view 
       internalFormat:(unsigned long)format
{
  [self notImplemented: _cmd];
}


- (int)currentVirtualScreen
{
  [self notImplemented: _cmd];

  return 0;
}

- (void)flushBuffer
{
  MAKE_DISPLAY(dpy);

  glXSwapBuffers(dpy, glx_drawable);
}

- (void)getValues:(long *)vals 
     forParameter:(NSOpenGLContextParameter)param
{
  //  TODO
  [self notImplemented: _cmd];
}

- (id)initWithCGLContextObj: (void *)context
{
  self = [super init];

  if (!self)
    {
      return nil;
    }
  if (!XGGLLoad())
    {
      RELEASE(self);
      return nil;
    }

  // FIXME: Need to set the pixelFormat ivar
  glx_context = context;
  return self;
}

- (id)initWithFormat: (NSOpenGLPixelFormat *)_format 
        shareContext: (NSOpenGLContext *)share
{
  self = [super init];

  if (!self)
    {
      return nil;
    }
  if (!XGGLLoad())
    {
      RELEASE(self);
      return nil;
    }

  glx_context = None;
  
  if (!_format || ![_format isKindOfClass: [XGGLPixelFormat class]])
    {
      NSDebugMLLog(@"GLX", @"Invalid format %@", _format);
      RELEASE(self);

      return nil;
    }

  ASSIGN(pixelFormat, (XGGLPixelFormat *)_format);
  
  glx_context = [pixelFormat createGLXContext: (XGGLContext *)share];
  
  return self;
}

- (void) dealloc
{
  NSDebugMLLog(@"GLX", @"Deallocating");

  [self _detach];
  RELEASE(pixelFormat);

  if (glx_context != None)
    {
      MAKE_DISPLAY(dpy);
      glXDestroyContext(dpy, glx_context);
    }

  [super dealloc];
}

- (void) makeCurrentContext
{
  MAKE_DISPLAY(dpy);

  [self _attachAgainIfWindowGone];
  if (xSubWindow == nil)
    {
      [NSException raise: NSGenericException
		          format: @"GL Context has no view attached, cannot be\
                            made current"];
    }
  
  NSAssert(glx_context != None && glx_drawable != None,
	   NSInternalInconsistencyException);

  if ([XGGLPixelFormat glxMinorVersion] >= 3)
    {
      if (!glXMakeContextCurrent(dpy, glx_drawable, glx_drawable, glx_context) )
        {
          NSDebugMLLog(@"GLX", @"Cannot make GL context %@ current - Error %s",
                       self, glGetString(glGetError()));
        }
    }
  else
    {
      if (!glXMakeCurrent(dpy, glx_drawable, glx_context) )
        {
          NSDebugMLLog(@"GLX", @"Cannot make GL context %@ current - Error %s",
                       self, glGetString(glGetError()));
        }
    }

  currentGLContext = self;
}

- (void)setCurrentVirtualScreen:(int)screen
{
  [self notImplemented: _cmd];
}

- (void)setFullScreen
{
  [self notImplemented: _cmd];
}

- (void)setOffScreen:(void *)baseaddr 
               width:(long)width 
              height:(long)height 
            rowbytes:(long)rowbytes
{
  [self notImplemented: _cmd];
}

- (void)setValues:(const long *)vals 
     forParameter:(NSOpenGLContextParameter)param
{
  [self notImplemented: _cmd];
}

- (void)setView:(NSView *)view
{
  NSView *current_view;

  if (!view)
    {
      [NSException raise: NSInvalidArgumentException
		          format: @"setView called with a nil value"];
    }

  NSAssert(pixelFormat, NSInternalInconsistencyException);
  current_view = [self view];

  if ( current_view != nil )
    {
      [current_view _setIgnoresBacking: saved_ignores_backing];
    }

  /* The old drawable and X window go first; the GLX context stays, so the
   * view draws with the same context, its objects and state, after
   * attaching again.  (The old GLX window used to be left behind, on an X
   * window destroyed whenever the old subwindow object was freed.)  */
  [self _detach];
  ASSIGN(xSubWindow, [XGXSubWindow subwindowOnView: view 
                                        visualinfo: [pixelFormat visualinfo]]);

  glx_drawable = [pixelFormat drawableForWindow: xSubWindow->xwindowid];
  saved_ignores_backing = [view _ignoresBacking];
  [view _setIgnoresBacking: YES];

  NSDebugMLLog(@"GLX", @"glx_window : %lu", (unsigned long) glx_drawable);
}

- (void)update
{
  [self _attachAgainIfWindowGone];
  [xSubWindow update];
}

- (NSView *)view
{
  if (xSubWindow)
    {
      return xSubWindow->attached;
    }
  else
    {
      return nil;
    }
}

@end
#endif
