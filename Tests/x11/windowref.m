/* -[NSWindow windowRef] answers the display server's -windowDevice:, which
 * for X11 is the X window id itself, and -[NSWindow initWithWindowRef:]
 * hands its argument to -nativeWindow:::::.  So the window device of one
 * window must be accepted by -nativeWindow::::: to wrap the same X window.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) && BUILD_SERVER == SERVER_x11

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>

int
main(int argc, const char **argv)
{
  START_SET("native window from window device")

  extern void		initialize_gnustep_backend(void);
  GSDisplayServer	*srv = nil;
  NSRect		frame = NSZeroRect;
  NSBackingStoreType	type = NSBackingStoreBuffered;
  unsigned int		style = NSTitledWindowMask;
  int			screen = -1;
  int			win;
  int			wrapped;
  void			*device;

  if (getenv("DISPLAY") == NULL || *getenv("DISPLAY") == '\0')
    {
      SKIP("no window server available")
    }

  NS_DURING
    {
      initialize_gnustep_backend();
      srv = [GSDisplayServer serverWithAttributes: nil];
    }
  NS_HANDLER
    {
      NSLog(@"the display server did not start: %@", localException);
      SKIP("It looks like the GNUstep backend is not installed")
    }
  NS_ENDHANDLER

  if (srv == nil || [srv isMemberOfClass: [GSDisplayServer class]])
    {
      SKIP("no concrete display server")
    }
  [GSDisplayServer setCurrentServer: srv];

  win = [srv window: NSMakeRect(10, 10, 120, 80)
		   : NSBackingStoreBuffered
		   : NSBorderlessWindowMask];
  device = [srv windowDevice: win];
  PASS(device != NULL, "a window has a window device");

  wrapped = [srv nativeWindow: device : &frame : &type : &style : &screen];
  PASS(wrapped > 0 && wrapped != win,
    "the window device of a window can be wrapped as a native window");
  PASS([srv windowDevice: wrapped] == device,
    "the wrapped window has the same window device");
  PASS(screen >= 0, "the wrapped window reports its screen");

  [srv termwindow: win];

  END_SET("native window from window device")

  return 0;
}

#else

int
main(int argc, const char **argv)
{
  START_SET("native window from window device")
    SKIP("back is not built with the x11 server")
  END_SET("native window from window device")
  return 0;
}

#endif
