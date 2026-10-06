/* The alpha channel of borderless windows (GSBackBorderlessWindowAlpha):
 * with the default YES and a compositing manager running, a borderless
 * window (a menu, a tool tip) is made with a 32-bit visual, so what the gui
 * leaves transparent, such as rounded corners, shows what is behind it.
 * Without the default, without a compositing manager (transparent pixels
 * would show black), or for a window with a style, it keeps the screen's
 * visual.
 *
 * The test forks a compositing manager (FakeCompositor.h), so it needs a
 * display with none of its own (a private Xvfb).
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) && BUILD_SERVER == SERVER_x11 \
  && defined(XRENDER)

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
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

/* Lets the backend handle what the X server sent it, such as the news
   that the compositing manager has stopped. */
static void
spin(void)
{
  [[NSRunLoop currentRunLoop]
    runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.4]];
}

/* The depth of the server's X window for a new window of that style. */
static int
depthOfNewWindow(GSDisplayServer *srv, Display *dpy, NSUInteger style)
{
  int			win;
  XWindowAttributes	a;
  int			depth = 0;

  win = [srv window: NSMakeRect(100, 100, 200, 100)
		   : NSBackingStoreBuffered : style : 0];
  XSync((Display *)[srv serverDevice], False);
  if (XGetWindowAttributes(dpy, (Window)[srv windowDevice: win], &a))
    {
      depth = a.depth;
    }
  [srv termwindow: win];
  return depth;
}

int
main(int argc, const char **argv)
{
  START_SET("borderless window alpha")

  extern void		initialize_gnustep_backend(void);
  GSDisplayServer	*srv = nil;
  Display		*dpy;
  pid_t			compositor;

  if (getenv("DISPLAY") == NULL || *getenv("DISPLAY") == '\0')
    {
      SKIP("no window server available")
    }
  dpy = XOpenDisplay(NULL);
  if (dpy == NULL)
    {
      SKIP("no window server available")
    }
  if (XGetSelectionOwner(dpy, fakeCompositorSelection(dpy)) != None)
    {
      SKIP("the display has a compositing manager of its own")
    }
  compositor = fakeCompositorStart(dpy);
  if (compositor < 0)
    {
      SKIP("the test compositing manager did not start")
    }

  NS_DURING
    {
      initialize_gnustep_backend();
      srv = [GSDisplayServer serverWithAttributes: nil];
    }
  NS_HANDLER
    {
      NSLog(@"the display server did not start: %@", localException);
      fakeCompositorStop(dpy, compositor);
      SKIP("It looks like the GNUstep backend is not installed")
    }
  NS_ENDHANDLER
  if (srv == nil || [srv isMemberOfClass: [GSDisplayServer class]])
    {
      fakeCompositorStop(dpy, compositor);
      SKIP("no concrete display server")
    }
  [GSDisplayServer setCurrentServer: srv];

  PASS(depthOfNewWindow(srv, dpy, NSBorderlessWindowMask) != 32,
    "without GSBackBorderlessWindowAlpha a borderless window has no alpha"
    " channel");

  setDefault(@"YES", @"GSBackBorderlessWindowAlpha");
  PASS(depthOfNewWindow(srv, dpy, NSBorderlessWindowMask) == 32,
    "with GSBackBorderlessWindowAlpha and a compositing manager a borderless"
    " window has an alpha channel");
  PASS(depthOfNewWindow(srv, dpy, NSTitledWindowMask | NSClosableWindowMask)
    != 32,
    "GSBackBorderlessWindowAlpha leaves windows with a style alone");

  fakeCompositorStop(dpy, compositor);
  spin();
  PASS(depthOfNewWindow(srv, dpy, NSBorderlessWindowMask) != 32,
    "without a compositing manager a borderless window has no alpha channel");

  XCloseDisplay(dpy);

  END_SET("borderless window alpha")

  return 0;
}

#else

int
main(int argc, const char **argv)
{
  START_SET("borderless window alpha")
    SKIP("back is not built with the x11 server and XRender")
  END_SET("borderless window alpha")
  return 0;
}

#endif
