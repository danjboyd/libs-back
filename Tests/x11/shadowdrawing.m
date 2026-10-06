/* What a window with a shadow margin (GSBackWindowShadows) shows: the
 * gui's drawing inside its visible part, opaque, with that part's corners
 * rounded (GSBackWindowCornerRadius), and round it a black shadow that is
 * strongest at the edge, fades out across the margin, and is stronger
 * below the window than above it.
 *
 * The test forks a window manager that knows _GTK_FRAME_EXTENTS
 * (FakeCSDWindowManager.h) and a compositing manager (FakeCompositor.h),
 * orders a window in and reads the alpha of its X window's pixels back.
 * It needs a display with neither (a private Xvfb).
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) && BUILD_SERVER == SERVER_x11 \
  && defined(HAVE_XSHAPE) && defined(XRENDER)

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#include <X11/Xutil.h>
#include <string.h>
#include "FakeCSDWindowManager.h"
#include "FakeCompositor.h"

/* Sets a default for this process only, in the argument domain. */
static void
setDefault(id value, NSString *key)
{
  NSUserDefaults	*defs = [NSUserDefaults standardUserDefaults];
  NSMutableDictionary	*args;

  args = [[defs volatileDomainForName: NSArgumentDomain] mutableCopy];
  if (args == nil)
    {
      args = [NSMutableDictionary new];
    }
  [args setObject: value forKey: key];
  [defs removeVolatileDomainForName: NSArgumentDomain];
  [defs setVolatileDomain: args forName: NSArgumentDomain];
  [args release];
}

static void
spin(NSTimeInterval seconds)
{
  [[NSRunLoop currentRunLoop]
    runUntilDate: [NSDate dateWithTimeIntervalSinceNow: seconds]];
}

/* The window's _GTK_FRAME_EXTENTS: left, right, top, bottom. */
static BOOL
frameExtents(Display *dpy, Window w, unsigned long extents[4])
{
  Atom		type;
  int		format;
  unsigned long	n, after;
  unsigned char	*data = NULL;
  BOOL		found = NO;

  if (XGetWindowProperty(dpy, w, XInternAtom(dpy, "_GTK_FRAME_EXTENTS", False),
      0, 4, False, XA_CARDINAL, &type, &format, &n, &after, &data) == Success
    && data != NULL)
    {
      if (n == 4)
	{
	  memcpy(extents, data, 4 * sizeof(unsigned long));
	  found = YES;
	}
      XFree(data);
    }
  return found;
}

/* Orders the window in, lets it draw, and answers its X window's pixels,
 * with the X window's size in a and its _GTK_FRAME_EXTENTS in extents;
 * NULL when the X window has no alpha channel or no extents.
 */
static XImage *
grab(Display *dpy, NSWindow *window, XWindowAttributes *a,
  unsigned long extents[4])
{
  Window	xwin;

  [window orderFront: nil];
  [window display];
  [window flushWindow];
  spin(0.5);
  xwin = (Window)[GSCurrentServer() windowDevice: [window windowNumber]];
  XSync((Display *)[GSCurrentServer() serverDevice], False);
  if (XGetWindowAttributes(dpy, xwin, a) == 0 || a->depth != 32
    || frameExtents(dpy, xwin, extents) == NO)
    {
      return NULL;
    }
  return XGetImage(dpy, xwin, 0, 0, a->width, a->height, AllPlanes, ZPixmap);
}

/* The alpha (0-255) of a pixel of a 32-bit image. */
static int
alphaAt(XImage *image, int x, int y)
{
  return (int)((XGetPixel(image, x, y) >> 24) & 0xff);
}

int
main(int argc, const char **argv)
{
  START_SET("shadow drawing")

  Display		*dpy;
  pid_t			wm;
  pid_t			compositor;
  NSWindow		*window;
  XWindowAttributes	a;
  XImage		*image;
  unsigned long		extents[4];

  if (getenv("DISPLAY") == NULL || *getenv("DISPLAY") == '\0')
    {
      SKIP("no window server available")
    }
  dpy = XOpenDisplay(NULL);
  if (dpy == NULL)
    {
      SKIP("no window server available")
    }
  XSetErrorHandler(fakeCSDWMIgnoreError);
  if (XGetSelectionOwner(dpy, XInternAtom(dpy, "WM_S0", False)) != None
    || XGetSelectionOwner(dpy, fakeCompositorSelection(dpy)) != None)
    {
      SKIP("the display has a window or compositing manager of its own")
    }
  wm = fakeCSDWMStart(dpy);
  if (wm < 0)
    {
      SKIP("the test window manager did not start")
    }
  compositor = fakeCompositorStart(dpy);
  if (compositor < 0)
    {
      fakeCSDWMStop(wm);
      SKIP("the test compositing manager did not start")
    }

  setDefault(@"NO", @"GSBackHandlesWindowDecorations");
  setDefault(@"YES", @"GSIgnoreRootOffsets");
  setDefault(@"YES", @"GSBackWindowShadows");
  setDefault(@"12", @"GSBackWindowCornerRadius");
  NS_DURING
    {
      [NSApplication sharedApplication];
    }
  NS_HANDLER
    {
      fakeCompositorStop(dpy, compositor);
      fakeCSDWMStop(wm);
      SKIP("It looks like the GNUstep backend is not installed")
    }
  NS_ENDHANDLER

  window = [[NSWindow alloc]
    initWithContentRect: NSMakeRect(100, 100, 400, 300)
	      styleMask: NSTitledWindowMask | NSClosableWindowMask
			 | NSResizableWindowMask
		backing: NSBackingStoreBuffered
		  defer: NO];
#if HAVE_XFIXES
  image = grab(dpy, window, &a, extents);
  PASS(image != NULL && a.width > NSWidth([window frame])
    && a.height > NSHeight([window frame]),
    "a window has a 32-bit X window with a margin round its frame");
  if (image != NULL)
    {
      /* The visible part of the X window. */
      int	left = extents[0];
      int	right = a.width - extents[1];
      int	top = extents[2];
      int	bottom = a.height - extents[3];
      int	midX = (left + right) / 2;
      int	midY = (top + bottom) / 2;

      PASS(alphaAt(image, midX, midY) == 255,
	"the window's contents are opaque");
      PASS(alphaAt(image, midX, top) == 255,
	"the top edge of the visible part is opaque between the corners");
      PASS(alphaAt(image, left, top) < 128
	&& alphaAt(image, right - 1, top) < 128,
	"the top corners of the visible part are rounded off (%d, %d)",
	alphaAt(image, left, top), alphaAt(image, right - 1, top));
      PASS(alphaAt(image, left - 1, midY) >= 30
	&& alphaAt(image, left - 1, midY) <= 60,
	"beside the window the shadow is about 19%% black (%d)",
	alphaAt(image, left - 1, midY));
      PASS(alphaAt(image, 0, midY) < alphaAt(image, left - 10, midY)
	&& alphaAt(image, left - 10, midY) < alphaAt(image, left - 1, midY)
	&& alphaAt(image, 0, midY) <= 8,
	"the shadow fades out across the margin (%d, %d, %d)",
	alphaAt(image, left - 1, midY), alphaAt(image, left - 10, midY),
	alphaAt(image, 0, midY));
      PASS(alphaAt(image, midX, bottom) > alphaAt(image, midX, top - 1),
	"the shadow is stronger below the window than above it (%d, %d)",
	alphaAt(image, midX, bottom), alphaAt(image, midX, top - 1));
      PASS(alphaAt(image, 0, 0) <= 2,
	"the margin's far corner is transparent (%d)", alphaAt(image, 0, 0));
      XDestroyImage(image);
    }
#else
  /* Built without XFixes no window gets a margin (shadowmargin.m). */
  {
    Window	xwin;

    [window orderFront: nil];
    [window display];
    [window flushWindow];
    spin(0.5);
    xwin = (Window)[GSCurrentServer() windowDevice: [window windowNumber]];
    XSync((Display *)[GSCurrentServer() serverDevice], False);
    PASS(XGetWindowAttributes(dpy, xwin, &a) != 0 && a.depth != 32
      && frameExtents(dpy, xwin, extents) == NO,
      "without XFixes a window has no margin to draw a shadow in");
  }
#endif
  [window close];

  fakeCompositorStop(dpy, compositor);
  fakeCSDWMStop(wm);
  XCloseDisplay(dpy);

  END_SET("shadow drawing")

  return 0;
}

#else

int
main(int argc, const char **argv)
{
  START_SET("shadow drawing")
    SKIP("back is not built with the x11 server, XShape and XRender")
  END_SET("shadow drawing")
  return 0;
}

#endif
