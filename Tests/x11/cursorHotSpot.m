/* A cursor's hot spot is in points, and an image's representation can have more
   pixels than that, so the X cursor's hot spot has to scale with it.  Reads the
   cursor the X server has with XFixes. */
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) && BUILD_SERVER == SERVER_x11 \
  && __has_include(<X11/extensions/Xfixes.h>)

#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSGeometry.h>
#import <Foundation/NSRunLoop.h>

#import <AppKit/NSApplication.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSCursor.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSScreen.h>
#import <AppKit/NSWindow.h>

#include <X11/Xlib.h>
#include <X11/extensions/Xfixes.h>

static NSImage *
imageWithPixels(NSInteger wide, NSInteger high, NSSize size)
{
  NSBitmapImageRep *rep;
  NSImage *image;

  rep = AUTORELEASE([[NSBitmapImageRep alloc]
    initWithBitmapDataPlanes: NULL
                  pixelsWide: wide
                  pixelsHigh: high
               bitsPerSample: 8
             samplesPerPixel: 4
                    hasAlpha: YES
                    isPlanar: NO
              colorSpaceName: NSDeviceRGBColorSpace
                 bytesPerRow: 0
                bitsPerPixel: 0]);
  memset([rep bitmapData], 0xff, [rep bytesPerRow] * high);
  [rep setSize: size];
  image = AUTORELEASE([[NSImage alloc] initWithSize: size]);
  [image addRepresentation: rep];
  return image;
}

/* Sets the cursor and reads back what the X server has. */
static BOOL
serverCursor(Display *dpy, NSImage *image, NSPoint hot,
  int *w, int *h, int *xhot, int *yhot)
{
  NSCursor *cursor;
  XFixesCursorImage *c;

  cursor = AUTORELEASE([[NSCursor alloc] initWithImage: image hotSpot: hot]);
  [cursor set];
  [[NSRunLoop currentRunLoop] runUntilDate:
    [NSDate dateWithTimeIntervalSinceNow: 0.1]];
  XSync(dpy, False);
  c = XFixesGetCursorImage(dpy);
  if (c == NULL)
    {
      return NO;
    }
  *w = c->width;
  *h = c->height;
  *xhot = c->xhot;
  *yhot = c->yhot;
  XFree(c);
  return YES;
}

int
main(int argc, char **argv)
{
  START_SET("X cursor hot spot")

  NS_DURING
    [NSApplication sharedApplication];
  NS_HANDLER
    if ([[localException name] isEqualToString: NSInternalInconsistencyException])
      SKIP("It looks like GNUstep backend is not yet installed")
  NS_ENDHANDLER

  NS_DURING
    {
      Display *dpy = XOpenDisplay(NULL);
      int event, error;
      NSWindow *w;
      int cw, ch, xhot, yhot;
      int x1, y1;

      if (dpy == NULL || !XFixesQueryExtension(dpy, &event, &error))
        {
          SKIP("The X server has no XFixes")
        }
      w = AUTORELEASE([[NSWindow alloc]
        initWithContentRect: [[NSScreen mainScreen] frame]
                  styleMask: NSBorderlessWindowMask
                    backing: NSBackingStoreBuffered
                      defer: NO]);
      [w orderFront: nil];
      [[NSRunLoop currentRunLoop] runUntilDate:
        [NSDate dateWithTimeIntervalSinceNow: 0.3]];
      XWarpPointer(dpy, None, DefaultRootWindow(dpy), 0, 0, 0, 0, 100, 100);
      XSync(dpy, False);

      /* One pixel a point: the reference, whichever way y runs. */
      PASS(serverCursor(dpy, imageWithPixels(16, 16, NSMakeSize(16, 16)),
        NSMakePoint(4, 12), &cw, &ch, &x1, &y1), "the cursor can be read back");
      PASS(cw == 16 && ch == 16, "a 16 pixel cursor is 16 pixels");
      PASS(x1 == 4 && (y1 == 12 || y1 == 4), "the hot spot is where it was put");

      /* Two pixels a point. */
      serverCursor(dpy, imageWithPixels(32, 32, NSMakeSize(16, 16)),
        NSMakePoint(4, 12), &cw, &ch, &xhot, &yhot);
      PASS(cw == 32 && ch == 32, "a 32 pixel cursor is 32 pixels");
      PASS(xhot == 2 * x1, "x of the hot spot scales with the pixels");
      PASS(yhot == 2 * y1, "y of the hot spot scales with the pixels");

      /* Different scales across and down. */
      serverCursor(dpy, imageWithPixels(32, 48, NSMakeSize(16, 16)),
        NSMakePoint(4, 12), &cw, &ch, &xhot, &yhot);
      PASS(xhot == 2 * x1 && yhot == 3 * y1, "each axis scales by its own ratio");

      /* A hot spot at the far edge stays inside the cursor. */
      serverCursor(dpy, imageWithPixels(32, 32, NSMakeSize(16, 16)),
        NSMakePoint(16, 16), &cw, &ch, &xhot, &yhot);
      PASS(xhot >= 0 && xhot < 32 && yhot >= 0 && yhot < 32,
        "a hot spot at the edge stays inside");

      /* An image with 1x and 2x representations: the cursor is the one that
         suits the screen, not the largest. */
      {
        NSImage *both = imageWithPixels(16, 16, NSMakeSize(16, 16));
        NSImage *big = imageWithPixels(32, 32, NSMakeSize(16, 16));
        CGFloat factor = [[NSScreen mainScreen] userSpaceScaleFactor];
        int want = (factor > 1.0) ? 32 : 16;

        [both addRepresentation:
          [[big representations] objectAtIndex: 0]];
        serverCursor(dpy, both, NSMakePoint(4, 12), &cw, &ch, &xhot, &yhot);
        PASS(cw == want && ch == want,
          "of 1x and 2x representations, the cursor uses the screen's");
        PASS(xhot == x1 * want / 16, "and its hot spot scales with it");
      }

      [w orderOut: nil];
      XCloseDisplay(dpy);
    }
  NS_HANDLER
    if ([[localException name] isEqualToString: NSInternalInconsistencyException]
      || [[localException name] isEqualToString: @"NSWindowServerCommunicationException"])
      SKIP("No display available")
    else
      [localException raise];
  NS_ENDHANDLER

  END_SET("X cursor hot spot")

  return 0;
}

#else

int
main(int argc, char **argv)
{
  START_SET("X cursor hot spot")
    SKIP("This needs the x11 backend and XFixes")
  END_SET("X cursor hot spot")
  return 0;
}

#endif
