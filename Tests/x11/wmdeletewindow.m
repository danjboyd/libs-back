/* WM_DELETE_WINDOW on windows whose decorations the gui library draws
 * (GSBackHandlesWindowDecorations NO).  Their X windows are created without
 * the window's style, but a closable window must still list WM_DELETE_WINDOW
 * in WM_PROTOCOLS once it is ordered in.  Without it a window manager asked
 * to close the window (Alt+F4, its window menu) has no way to ask, and
 * Mutter, for one, kills the client instead.  Windows that aren't closable
 * must not list it.
 *
 * Only the property the backend sets is read, so the test works with or
 * without a window manager on the display.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) && BUILD_SERVER == SERVER_x11

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>

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

/* Orders a window of the given style in, and answers whether its X window
 * lists WM_DELETE_WINDOW.  The backend's own connection is flushed first:
 * what it set may still be in its buffer.
 */
static BOOL
listsDeleteWindow(Display *dpy, unsigned int style)
{
  NSWindow		*win;
  GSDisplayServer	*srv;
  Window		w;
  Atom			deleteAtom = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
  Atom			*protocols = NULL;
  int			count = 0;
  int			i;
  BOOL			found = NO;

  win = [[NSWindow alloc] initWithContentRect: NSMakeRect(100, 100, 300, 200)
				    styleMask: style
				      backing: NSBackingStoreBuffered
					defer: NO];
  [win setReleasedWhenClosed: NO];
  [win orderFront: nil];
  srv = GSServerForWindow(win);
  w = (Window)[srv windowDevice: [win windowNumber]];
  XSync((Display *)[srv serverDevice], False);

  if (XGetWMProtocols(dpy, w, &protocols, &count) != 0)
    {
      for (i = 0; i < count; i++)
	{
	  if (protocols[i] == deleteAtom)
	    {
	      found = YES;
	    }
	}
      XFree(protocols);
    }
  [win orderOut: nil];
  [win release];
  return found;
}

int
main(int argc, const char **argv)
{
  START_SET("WM_DELETE_WINDOW")

  NSAutoreleasePool	*pool = [NSAutoreleasePool new];
  Display		*dpy;
  BOOL			started = NO;

  if (getenv("DISPLAY") == NULL || *getenv("DISPLAY") == '\0')
    {
      SKIP("no window server available")
    }
  dpy = XOpenDisplay(NULL);
  if (dpy == NULL)
    {
      SKIP("no window server available")
    }

  setDefault(@"NO", @"GSBackHandlesWindowDecorations");
  NS_DURING
    {
      [NSApplication sharedApplication];
      started = YES;
    }
  NS_HANDLER
    {
      NSLog(@"the application did not start: %@", localException);
    }
  NS_ENDHANDLER
  if (started == NO || GSCurrentServer() == nil
    || [GSCurrentServer() isMemberOfClass: [GSDisplayServer class]])
    {
      SKIP("It looks like the GNUstep backend is not installed")
    }

  PASS([GSCurrentServer() handlesWindowDecorations] == NO,
    "with GSBackHandlesWindowDecorations NO the gui draws the decorations");

  PASS(listsDeleteWindow(dpy, NSTitledWindowMask | NSClosableWindowMask
    | NSMiniaturizableWindowMask | NSResizableWindowMask) == YES,
    "a fully styled window lists WM_DELETE_WINDOW");

  PASS(listsDeleteWindow(dpy, NSTitledWindowMask | NSClosableWindowMask)
    == YES,
    "a closable window that isn't resizable lists WM_DELETE_WINDOW");

  PASS(listsDeleteWindow(dpy, NSTitledWindowMask | NSResizableWindowMask)
    == NO,
    "a window that isn't closable doesn't list WM_DELETE_WINDOW");

  PASS(listsDeleteWindow(dpy, NSBorderlessWindowMask) == NO,
    "a borderless window doesn't list WM_DELETE_WINDOW");

  XCloseDisplay(dpy);
  [pool release];

  END_SET("WM_DELETE_WINDOW")

  return 0;
}

#else

int
main(int argc, const char **argv)
{
  START_SET("WM_DELETE_WINDOW")
    SKIP("back is not built with the x11 server")
  END_SET("WM_DELETE_WINDOW")
  return 0;
}

#endif
