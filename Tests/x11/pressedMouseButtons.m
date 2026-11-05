/* NSEvent asks the display server which mouse buttons are down, and the X11
 * server answers from the pointer's state.  XTest presses the buttons, and is
 * loaded when the test runs because it's not otherwise needed to build.
 */
#import <Foundation/NSObject.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) && BUILD_SERVER == SERVER_x11

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#include <X11/Xlib.h>
#include <dlfcn.h>

typedef int (*FakeButton)(Display *, unsigned, Bool, unsigned long);

static NSUInteger
whileHeld(Display *dpy, FakeButton fake, unsigned button)
{
  NSUInteger	buttons;

  fake(dpy, button, True, 0);
  XSync(dpy, False);
  buttons = [NSEvent pressedMouseButtons];
  fake(dpy, button, False, 0);
  XSync(dpy, False);
  return buttons;
}

int
main(int argc, const char **argv)
{
  START_SET("pressed mouse buttons")

  Display	*dpy;
  void		*xtst;
  FakeButton	fake;

  NS_DURING
    {
      [NSApplication sharedApplication];
      if (nil == GSCurrentServer())
	{
	  SKIP("no window server available")
	}
    }
  NS_HANDLER
    {
      SKIP("It looks like the GNUstep backend is not installed")
    }
  NS_ENDHANDLER

  xtst = dlopen("libXtst.so.6", RTLD_NOW);
  fake = xtst ? (FakeButton)dlsym(xtst, "XTestFakeButtonEvent") : NULL;
  dpy = XOpenDisplay(NULL);
  if (fake == NULL || dpy == NULL)
    {
      SKIP("XTest isn't available")
    }

  PASS([NSEvent pressedMouseButtons] == 0, "no buttons are down at first")
  PASS(whileHeld(dpy, fake, 1) == 1 << 0, "the left button is bit 0")
  PASS(whileHeld(dpy, fake, 3) == 1 << 1, "the right button is bit 1")
  PASS(whileHeld(dpy, fake, 2) == 1 << 2, "the middle button is bit 2")
  PASS([NSEvent pressedMouseButtons] == 0, "released buttons aren't reported")

  fake(dpy, 1, True, 0);
  fake(dpy, 3, True, 0);
  XSync(dpy, False);
  PASS([NSEvent pressedMouseButtons] == ((1 << 0) | (1 << 1)),
    "two buttons down together are both reported")
  fake(dpy, 1, False, 0);
  fake(dpy, 3, False, 0);
  XSync(dpy, False);

  XCloseDisplay(dpy);
  END_SET("pressed mouse buttons")
  return 0;
}

#else

int
main(int argc, const char **argv)
{
  START_SET("pressed mouse buttons")
  SKIP("back is not built with the x11 display server")
  END_SET("pressed mouse buttons")
  return 0;
}

#endif
