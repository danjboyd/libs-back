/* The shadow margin of windows the gui decorates (GSBackWindowShadows):
 * a transparent margin round the frame with a 32-bit visual,
 * _GTK_FRAME_EXTENTS telling the window manager where the window is, an
 * input shape of the visible part plus a resize band, no margin while the
 * window manager has the window maximized or while no compositing manager
 * runs, a margin that grows with GSScaleFactor, and none at all for a
 * non-retained window, a borderless one, or a window manager that doesn't
 * know _GTK_FRAME_EXTENTS.
 *
 * The test forks a window manager that knows _GTK_FRAME_EXTENTS
 * (FakeCSDWindowManager.h) and a compositing manager (FakeCompositor.h).
 * It needs a display with neither (a private Xvfb).
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) && BUILD_SERVER == SERVER_x11 \
  && defined(HAVE_XSHAPE) && defined(XRENDER)

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/extensions/shape.h>
#include "FakeCSDWindowManager.h"
#include "FakeCompositor.h"

/* Sets a default for this process only, in the argument domain, or
   removes it when value is nil. */
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
  if (value == nil)
    {
      [args removeObjectForKey: key];
    }
  else
    {
      [args setObject: value forKey: key];
    }
  [defs removeVolatileDomainForName: NSArgumentDomain];
  [defs setVolatileDomain: args forName: NSArgumentDomain];
  [args release];
}

/* The backend's own connection: what it asked for may still be in its
   buffer, so the helpers below flush it before they read. */
static Display	*serverDisplay = NULL;

static void
syncServer(Display *dpy)
{
  if (serverDisplay != NULL)
    {
      XSync(serverDisplay, False);
    }
  XSync(dpy, False);
}

/* Lets the backend handle what the X server sent it. */
static void
spin(void)
{
  [[NSRunLoop currentRunLoop]
    runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.4]];
}

/* The window's _GTK_FRAME_EXTENTS as "l r t b", or "none". */
static NSString *
frameExtents(Display *dpy, Window w)
{
  Atom		type;
  int		format;
  unsigned long	n, after;
  unsigned char	*data = NULL;
  NSString	*s = @"none";

  syncServer(dpy);
  if (XGetWindowProperty(dpy, w, XInternAtom(dpy, "_GTK_FRAME_EXTENTS", False),
      0, 4, False, XA_CARDINAL, &type, &format, &n, &after, &data) == Success
    && data != NULL)
    {
      unsigned long *v = (unsigned long *)data;

      if (n == 4)
	{
	  s = [NSString stringWithFormat: @"%lu %lu %lu %lu",
	    v[0], v[1], v[2], v[3]];
	}
      XFree(data);
    }
  return s;
}

static int
depthOf(Display *dpy, Window w)
{
  XWindowAttributes	a;

  syncServer(dpy);
  return XGetWindowAttributes(dpy, w, &a) ? a.depth : 0;
}

static NSSize
sizeOf(Display *dpy, Window w)
{
  XWindowAttributes	a;

  syncServer(dpy);
  return XGetWindowAttributes(dpy, w, &a)
    ? NSMakeSize(a.width, a.height) : NSZeroSize;
}

/* The input shape as one rectangle, or an empty rectangle when it is not
 * one. */
static NSRect
inputShape(Display *dpy, Window w)
{
  int		count = 0;
  int		ordering;
  XRectangle	*r;
  NSRect	result = NSZeroRect;

  syncServer(dpy);
  r = XShapeGetRectangles(dpy, w, ShapeInput, &count, &ordering);
  if (r != NULL)
    {
      if (count == 1)
	{
	  result = NSMakeRect(r[0].x, r[0].y, r[0].width, r[0].height);
	}
      XFree(r);
    }
  return result;
}

/* Which changed first, the size hints or _GTK_FRAME_EXTENTS, among the
   PropertyNotify events dpy has had since the last call: "hints",
   "extents" or "neither". */
static NSString *
firstChange(Display *dpy)
{
  Atom		extents = XInternAtom(dpy, "_GTK_FRAME_EXTENTS", False);
  NSString	*first = nil;
  XEvent	e;

  syncServer(dpy);
  while (XPending(dpy) > 0)
    {
      XNextEvent(dpy, &e);
      if (first == nil && e.type == PropertyNotify)
	{
	  if (e.xproperty.atom == XA_WM_NORMAL_HINTS)
	    {
	      first = @"hints";
	    }
	  else if (e.xproperty.atom == extents)
	    {
	      first = @"extents";
	    }
	}
    }
  return first == nil ? @"neither" : first;
}

static void
setMaximized(Display *dpy, Window w, BOOL maximized)
{
  Atom	state[2];

  state[0] = XInternAtom(dpy, "_NET_WM_STATE_MAXIMIZED_VERT", False);
  state[1] = XInternAtom(dpy, "_NET_WM_STATE_MAXIMIZED_HORZ", False);
  XChangeProperty(dpy, w, XInternAtom(dpy, "_NET_WM_STATE", False), XA_ATOM,
    32, PropModeReplace, (unsigned char *)state, maximized ? 2 : 0);
  XFlush(dpy);
}

int
main(int argc, const char **argv)
{
  START_SET("shadow margin")

  extern void	initialize_gnustep_backend(void);
  NSUInteger		styled = NSTitledWindowMask | NSClosableWindowMask
    | NSMiniaturizableWindowMask | NSResizableWindowMask;
  GSDisplayServer	*srv = nil;
  Display		*dpy;
  pid_t			wm;
  pid_t			compositor;
  int			win;
  Window		xwin;
  NSRect		shape;
  NSSize		size;

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
  if (XGetSelectionOwner(dpy, fakeCompositorSelection(dpy)) != None)
    {
      SKIP("the display has a compositing manager of its own")
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
  NS_DURING
    {
      initialize_gnustep_backend();
      srv = [GSDisplayServer serverWithAttributes: nil];
    }
  NS_HANDLER
    {
      fakeCSDWMStop(wm);
      fakeCompositorStop(dpy, compositor);
      SKIP("It looks like the GNUstep backend is not installed")
    }
  NS_ENDHANDLER
  [GSDisplayServer setCurrentServer: srv];
  serverDisplay = (Display *)[srv serverDevice];

  /* Without GSBackWindowShadows nothing changes. */
  win = [srv window: NSMakeRect(100, 100, 400, 300)
		   : NSBackingStoreBuffered : styled : 0];
  xwin = (Window)[srv windowDevice: win];
  PASS([frameExtents(dpy, xwin) isEqual: @"none"]
    && NSEqualSizes(sizeOf(dpy, xwin), NSMakeSize(400, 300)),
    "without GSBackWindowShadows a window has no margin");
  [srv termwindow: win];

  setDefault(@"YES", @"GSBackWindowShadows");
  setDefault(@"15", @"GSBackWindowCornerRadius");
  win = [srv window: NSMakeRect(100, 100, 400, 300)
		   : NSBackingStoreBuffered : styled : 0];
  xwin = (Window)[srv windowDevice: win];
  [srv orderwindow: NSWindowAbove : 0 : win];
  spin();
#if HAVE_XFIXES
  PASS(depthOf(dpy, xwin) == 32, "a window with a margin has an alpha channel");
  PASS_EQUAL(frameExtents(dpy, xwin), @"30 30 24 36",
    "_GTK_FRAME_EXTENTS gives the margin");
  PASS(NSEqualSizes(sizeOf(dpy, xwin), NSMakeSize(460, 360)),
    "the X window is the frame plus the margin");
  PASS(NSEqualRects(inputShape(dpy, xwin), NSMakeRect(18, 12, 424, 324)),
    "a resizable window takes input in its frame and a 12 pixel band");

  [srv placewindow: NSMakeRect(100, 100, 500, 350) : win];
  spin();
  shape = inputShape(dpy, xwin);
  PASS(NSEqualRects(shape, NSMakeRect(18, 12, 524, 374)),
    "the input shape follows a resize the program makes (%s)",
    [NSStringFromRect(shape) UTF8String]);

  setMaximized(dpy, xwin, YES);
  spin();
  PASS_EQUAL(frameExtents(dpy, xwin), @"0 0 0 0",
    "a maximized window has no margin");
  setMaximized(dpy, xwin, NO);
  spin();
  PASS_EQUAL(frameExtents(dpy, xwin), @"30 30 24 36",
    "the margin comes back when the window is restored");

  /* The minimum size includes the margin.  The window manager fits the X
     window to a new margin, keeping the visible part's size, so it must
     never hold the window at a minimum meant for the other margin: the
     smaller minimum comes before the margin goes, and the margin comes
     back before the larger minimum. */
  [srv setminsize: NSMakeSize(300, 200) : win];
  XSelectInput(dpy, xwin, PropertyChangeMask);
  firstChange(dpy);
  setMaximized(dpy, xwin, YES);
  spin();
  PASS_EQUAL(firstChange(dpy), @"hints",
    "on a maximize the smaller minimum comes before the margin goes");
  setMaximized(dpy, xwin, NO);
  spin();
  PASS_EQUAL(firstChange(dpy), @"extents",
    "on a restore the margin comes back before the larger minimum");
  XSelectInput(dpy, xwin, NoEventMask);

  fakeCompositorStop(dpy, compositor);
  spin();
  PASS_EQUAL(frameExtents(dpy, xwin), @"0 0 0 0",
    "without a compositing manager the window has no margin");
  compositor = fakeCompositorStart(dpy);
  spin();
  PASS_EQUAL(frameExtents(dpy, xwin), @"30 30 24 36",
    "the margin comes back with a compositing manager");
  [srv termwindow: win];

  /* The margin, the corners and the band are in points: they grow with
     the gui's scale factor. */
  setDefault(@"2", @"GSScaleFactor");
  win = [srv window: NSMakeRect(100, 100, 400, 300)
		   : NSBackingStoreBuffered : styled : 0];
  xwin = (Window)[srv windowDevice: win];
  [srv orderwindow: NSWindowAbove : 0 : win];
  spin();
  PASS_EQUAL(frameExtents(dpy, xwin), @"60 60 48 72",
    "with GSScaleFactor 2 the margin is twice as wide");
  shape = inputShape(dpy, xwin);
  PASS(NSEqualRects(shape, NSMakeRect(36, 24, 448, 348)),
    "with GSScaleFactor 2 the resize band is 24 pixels (%s)",
    [NSStringFromRect(shape) UTF8String]);
  setMaximized(dpy, xwin, YES);
  spin();
  setMaximized(dpy, xwin, NO);
  spin();
  PASS_EQUAL(frameExtents(dpy, xwin), @"60 60 48 72",
    "with GSScaleFactor 2 the margin comes back twice as wide");
  [srv termwindow: win];
  setDefault(nil, @"GSScaleFactor");
#else
  /* Built without XFixes, the backend can't tell when the compositing
     manager stops, when a margin would show black: no window gets one. */
  PASS([frameExtents(dpy, xwin) isEqual: @"none"] && depthOf(dpy, xwin) != 32,
    "without XFixes a window has no margin, as the backend couldn't follow"
    " the compositing manager");
  [srv termwindow: win];
#endif

  win = [srv window: NSMakeRect(100, 100, 400, 300)
		   : NSBackingStoreNonretained : styled : 0];
  xwin = (Window)[srv windowDevice: win];
  PASS([frameExtents(dpy, xwin) isEqual: @"none"],
    "a non-retained window has no margin");
  [srv termwindow: win];

  win = [srv window: NSMakeRect(100, 100, 200, 100)
		   : NSBackingStoreBuffered : NSBorderlessWindowMask : 0];
  xwin = (Window)[srv windowDevice: win];
  PASS([frameExtents(dpy, xwin) isEqual: @"none"],
    "a borderless window has no margin");
  [srv termwindow: win];

  fakeCompositorStop(dpy, compositor);
  spin();
  win = [srv window: NSMakeRect(100, 100, 400, 300)
		   : NSBackingStoreBuffered : styled : 0];
  xwin = (Window)[srv windowDevice: win];
  PASS([frameExtents(dpy, xwin) isEqual: @"none"] && depthOf(dpy, xwin) != 32,
    "a window made without a compositing manager has no margin");
  [srv termwindow: win];
  compositor = fakeCompositorStart(dpy);
  spin();

  /* A window manager that doesn't know _GTK_FRAME_EXTENTS. */
  {
    Atom	supported[2];

    supported[0] = XInternAtom(dpy, "_NET_SUPPORTING_WM_CHECK", False);
    supported[1] = XInternAtom(dpy, "_NET_WM_STATE", False);
    XChangeProperty(dpy, DefaultRootWindow(dpy),
      XInternAtom(dpy, "_NET_SUPPORTED", False), XA_ATOM, 32,
      PropModeReplace, (unsigned char *)supported, 2);
    XSync(dpy, False);
  }
  win = [srv window: NSMakeRect(100, 100, 400, 300)
		   : NSBackingStoreBuffered : styled : 0];
  xwin = (Window)[srv windowDevice: win];
  size = sizeOf(dpy, xwin);
  PASS([frameExtents(dpy, xwin) isEqual: @"none"]
    && NSEqualSizes(size, NSMakeSize(400, 300)),
    "under a window manager without _GTK_FRAME_EXTENTS there is no margin");
  [srv termwindow: win];

  fakeCompositorStop(dpy, compositor);
  fakeCSDWMStop(wm);
  XCloseDisplay(dpy);

  END_SET("shadow margin")

  return 0;
}

#else

int
main(int argc, const char **argv)
{
  START_SET("shadow margin")
    SKIP("back is not built with the x11 server, XShape and XRender")
  END_SET("shadow margin")
  return 0;
}

#endif
