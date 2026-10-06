/* Closing a buffered window whose backing nothing else holds.  The gui
 * lets go of a window's graphics state, and with it the window's backing
 * (the cairo surface, or art's XWindowBuffer), before it asks
 * the backend to terminate the window.  The backend must not then message
 * the freed backing through the window device's gdriver.  This runs on
 * every x11 graphics backend, without a window manager.
 *
 * Freed memory is filled (glibc's M_PERTURB) so that a message to the
 * freed backing crashes the test every time instead of now and then.
 * Without the GDriverHandlesTermination check in -termwindow:, art's
 * XWindowBuffer was messaged after it was freed.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) && BUILD_SERVER == SERVER_x11

#import <AppKit/AppKit.h>
#ifdef __GLIBC__
#include <malloc.h>
#endif

static void
spin(NSTimeInterval seconds)
{
  [[NSRunLoop currentRunLoop]
    runUntilDate: [NSDate dateWithTimeIntervalSinceNow: seconds]];
}

int
main(int argc, const char **argv)
{
  START_SET("closing a window whose backing went first")

  int	i;

#if defined(__GLIBC__) && defined(M_PERTURB)
  mallopt(M_PERTURB, 0xa5);
#endif
  if (getenv("DISPLAY") == NULL || *getenv("DISPLAY") == '\0')
    {
      SKIP("no window server available")
    }
  NS_DURING
    {
      [NSApplication sharedApplication];
    }
  NS_HANDLER
    {
      SKIP("It looks like the GNUstep backend is not installed")
    }
  NS_ENDHANDLER

  for (i = 0; i < 3; i++)
    {
      NSWindow	*window;

      {
	CREATE_AUTORELEASE_POOL(pool);

	window = [[NSWindow alloc]
	  initWithContentRect: NSMakeRect(100, 100, 200, 120)
		    styleMask: NSTitledWindowMask
		      backing: NSBackingStoreBuffered
			defer: NO];
	[window orderFront: nil];
	[window display];
	[window flushWindow];
	spin(0.2);
	[window orderOut: nil];
	spin(0.1);
	RELEASE(pool);
      }
      {
	CREATE_AUTORELEASE_POOL(pool);

	[window release];
	RELEASE(pool);
      }
      spin(0.1);
    }
  PASS(YES, "windows whose backing was freed first close");

  END_SET("closing a window whose backing went first")

  return 0;
}

#else

int
main(int argc, const char **argv)
{
  START_SET("closing a window whose backing went first")
    SKIP("back is not built with the x11 server")
  END_SET("closing a window whose backing went first")
  return 0;
}

#endif
