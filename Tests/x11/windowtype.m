/* The _NET_WM_WINDOW_TYPE of the gui's windows, as GTK types its own:
 * a tool tip is _TOOLTIP although its level is set before its window is
 * registered (libs-gui#965), a context menu is _POPUP_MENU, a drag image
 * is _DND, a modal panel is _DIALOG, and any other window at the pop-up
 * menu level stays _DIALOG.  The new types are followed by _DIALOG, what the window
 * had before, for window managers that don't know them.
 *
 * The test forks a window manager that announces itself as an EWMH one
 * and maps what asks to be.  It needs a display with no window manager of
 * its own (a private Xvfb).
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) && BUILD_SERVER == SERVER_x11

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

static int
ignoreErrors(Display *d, XErrorEvent *e)
{
  return 0;
}

/* Announces itself, lists the window types, and maps what asks to be. */
static void
windowManagerRun(void)
{
  Display	*dpy = XOpenDisplay(NULL);
  Window	root;
  Window	check;
  Atom		netCheck;
  Atom		supported[2];

  if (dpy == NULL)
    {
      _exit(1);
    }
  XSetErrorHandler(ignoreErrors);
  root = DefaultRootWindow(dpy);
  netCheck = XInternAtom(dpy, "_NET_SUPPORTING_WM_CHECK", False);
  check = XCreateSimpleWindow(dpy, root, -100, -100, 1, 1, 0, 0, 0);
  XChangeProperty(dpy, check, netCheck, XA_WINDOW, 32, PropModeReplace,
    (unsigned char *)&check, 1);
  supported[0] = netCheck;
  supported[1] = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
  XChangeProperty(dpy, root, XInternAtom(dpy, "_NET_SUPPORTED", False),
    XA_ATOM, 32, PropModeReplace, (unsigned char *)supported, 2);
  XSelectInput(dpy, root, SubstructureRedirectMask | SubstructureNotifyMask);
  XChangeProperty(dpy, root, netCheck, XA_WINDOW, 32, PropModeReplace,
    (unsigned char *)&check, 1);
  XFlush(dpy);
  for (;;)
    {
      XEvent	e;

      XNextEvent(dpy, &e);
      if (e.type == MapRequest)
	{
	  XMapWindow(dpy, e.xmaprequest.window);
	}
      XFlush(dpy);
    }
}

static pid_t
startWindowManager(void)
{
  pid_t	pid = fork();

  if (pid == 0)
    {
#ifdef __linux__
      /* Gone with the test, should it abort. */
      prctl(PR_SET_PDEATHSIG, SIGKILL);
#endif
      windowManagerRun();
      _exit(0);
    }
  return pid;
}

static void
stopWindowManager(pid_t pid)
{
  if (pid > 0)
    {
      kill(pid, SIGKILL);
      waitpid(pid, NULL, 0);
    }
}

static BOOL
waitForWindowManager(Display *dpy)
{
  Atom		netCheck = XInternAtom(dpy, "_NET_SUPPORTING_WM_CHECK", False);
  unsigned	i;

  for (i = 0; i < 100; i++)
    {
      Atom		type;
      int		format;
      unsigned long	n, after;
      unsigned char	*data = NULL;

      if (XGetWindowProperty(dpy, DefaultRootWindow(dpy), netCheck, 0, 1,
	  False, XA_WINDOW, &type, &format, &n, &after, &data) == Success
	&& data != NULL)
	{
	  XFree(data);
	  if (n > 0)
	    {
	      return YES;
	    }
	}
      usleep(50000);
    }
  return NO;
}

/* Lets the backend handle what the X server sent it. */
static void
spin(void)
{
  [[NSRunLoop currentRunLoop]
    runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.3]];
}

/* The window's _NET_WM_WINDOW_TYPE, in order of preference, each less its
 * _NET_WM_WINDOW_TYPE_ prefix and separated by spaces, or "none". */
static NSString *
windowType(Display *dpy, NSWindow *window)
{
  Window	w = (Window)[GSCurrentServer() windowDevice: [window windowNumber]];
  Atom		type;
  int		format;
  unsigned long	n, after, i;
  unsigned char	*data = NULL;
  NSMutableArray *names = [NSMutableArray array];

  XSync(dpy, False);
  if (XGetWindowProperty(dpy, w, XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False),
      0, 8, False, XA_ATOM, &type, &format, &n, &after, &data) == Success
    && data != NULL)
    {
      for (i = 0; i < n; i++)
	{
	  char	*name = XGetAtomName(dpy, ((Atom *)data)[i]);

	  [names addObject: [[NSString stringWithUTF8String: name]
	    substringFromIndex: strlen("_NET_WM_WINDOW_TYPE_")]];
	  XFree(name);
	}
      XFree(data);
    }
  return [names count] > 0 ? [names componentsJoinedByString: @" "] : @"none";
}

int
main(int argc, const char **argv)
{
  START_SET("window types")

  Display		*dpy;
  pid_t			wm;
  Class			toolTipClass;
  NSPanel		*toolTip;
  NSPanel		*modal;
  NSWindow		*popUpLevel;
  NSWindow		*dragWindow;
  NSWindow		*menuWindow;

  if (getenv("DISPLAY") == NULL || *getenv("DISPLAY") == '\0')
    {
      SKIP("no window server available")
    }
  dpy = XOpenDisplay(NULL);
  if (dpy == NULL)
    {
      SKIP("no window server available")
    }
  XSetErrorHandler(ignoreErrors);
  if (XGetSelectionOwner(dpy, XInternAtom(dpy, "WM_S0", False)) != None)
    {
      SKIP("the display has a window manager of its own")
    }

  wm = startWindowManager();
  if (!waitForWindowManager(dpy))
    {
      stopWindowManager(wm);
      SKIP("the test window manager did not start")
    }

  NS_DURING
    {
      [NSApplication sharedApplication];
    }
  NS_HANDLER
    {
      stopWindowManager(wm);
      SKIP("It looks like the GNUstep backend is not installed")
    }
  NS_ENDHANDLER

  /* As GSToolTips makes its window: deferred, its level set before it has
     an X window, so the backend first sees the level with no window
     registered for it. */
  toolTipClass = NSClassFromString(@"GSTTPanel");
  if (toolTipClass == Nil)
    {
      toolTipClass = [NSPanel class];
    }
  toolTip = [[toolTipClass alloc] initWithContentRect: NSMakeRect(0, 0, 100, 25)
					    styleMask: NSBorderlessWindowMask
					      backing: NSBackingStoreRetained
						defer: YES];
  [toolTip setLevel: NSPopUpMenuWindowLevel];
  [toolTip orderFront: nil];
  spin();
  PASS_EQUAL(windowType(dpy, toolTip),
    toolTipClass == [NSPanel class] ? @"DIALOG" : @"TOOLTIP DIALOG",
    "a tool tip is a tool tip (a dialog for window managers that don't know it)");

  /* A menu's window at the pop-up menu level, as a context menu's or a
     pop-up button's is.  (No menu in it: a font looked up here can read a
     font name the defaults have released, -[GSCInlineString copy]: message
     sent to deallocated instance, and the test harness aborts on that.) */
  menuWindow = [[NSClassFromString(@"NSMenuPanel") alloc]
    initWithContentRect: NSMakeRect(0, 0, 100, 50)
	      styleMask: NSBorderlessWindowMask
		backing: NSBackingStoreBuffered
		  defer: YES];
  [menuWindow setLevel: NSPopUpMenuWindowLevel];
  [menuWindow orderFront: nil];
  spin();
  PASS(menuWindow != nil
    && [windowType(dpy, menuWindow) isEqual: @"POPUP_MENU DIALOG"],
    "a context menu is a pop-up menu (a dialog for window managers that don't"
    " know it)");
  [menuWindow orderOut: nil];

  modal = [[NSPanel alloc] initWithContentRect: NSMakeRect(100, 100, 300, 120)
				     styleMask: NSBorderlessWindowMask
				       backing: NSBackingStoreBuffered
					 defer: NO];
  [modal setLevel: NSModalPanelWindowLevel];
  [modal orderFront: nil];
  spin();
  PASS_EQUAL(windowType(dpy, modal), @"DIALOG", "a modal panel is a dialog");

  popUpLevel = [[NSWindow alloc] initWithContentRect: NSMakeRect(100, 100, 50, 50)
					   styleMask: NSBorderlessWindowMask
					     backing: NSBackingStoreBuffered
					       defer: NO];
  [popUpLevel setLevel: NSPopUpMenuWindowLevel];
  [popUpLevel orderFront: nil];
  spin();
  PASS_EQUAL(windowType(dpy, popUpLevel), @"DIALOG",
    "another window at the pop-up menu level stays a dialog");

  /* The drag image's window, as XGDragView makes it: its class puts it
     at the pop-up menu level when it is ordered in. */
  dragWindow = [[NSClassFromString(@"XGRawWindow") alloc]
    initWithContentRect: NSMakeRect(100, 100, 32, 32)
	      styleMask: NSBorderlessWindowMask
		backing: NSBackingStoreBuffered
		  defer: NO];
  [dragWindow orderFront: nil];
  spin();
  PASS(dragWindow != nil
    && [windowType(dpy, dragWindow) isEqual: @"DND DIALOG"],
    "a drag image is a drag and drop window (a dialog for window managers"
    " that don't know it)");

  [toolTip close];
  [dragWindow close];
  [modal close];
  [popUpLevel close];
  stopWindowManager(wm);

  END_SET("window types")
  return 0;
}

#else

int
main(int argc, const char **argv)
{
  START_SET("window types")
    SKIP("x11 backend only")
  END_SET("window types")
  return 0;
}

#endif
