/* Closing a window with a shadow margin (GSBackWindowShadows) leaves the X
 * server with nothing to complain about.  The window's cairo surface holds a
 * Render Picture on the X window; finishing that surface after XDestroyWindow,
 * which frees the Picture too, gave RenderBadPicture each time a window closed.
 *
 * Three windows open, draw, are ordered out and released, and the test counts
 * the X errors meanwhile.  By default it forks a window manager that knows
 * _GTK_FRAME_EXTENTS (FakeCSDWindowManager.h) and a compositing manager
 * (FakeCompositor.h), so the windows get their margin; it needs a display with
 * neither (a private Xvfb).  That much checks the margin and that closing
 * gives no error, but it doesn't show the bug: the test managers never lead
 * cairo to make a Picture on the window.
 *
 * WINDOWTERM_REAL_WM=1 uses the display's own window and compositing manager
 * instead, and runs an NSAlert modally three times, as an application does.
 * Under GNOME Shell (gnome-shell --x11 on a private Xvfb, with a theme asking
 * for the margin) that shows the bug: 3 RenderBadPicture without the fix, 0
 * with it.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) && BUILD_SERVER == SERVER_x11 \
  && defined(HAVE_XSHAPE) && defined(XRENDER)

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xrender.h>
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

static int	renderErrorBase = 0;
static int	badPictures = 0;
static int	otherErrors = 0;

static int
countErrors(Display *d, XErrorEvent *e)
{
  if (e->error_code == renderErrorBase + BadPicture)
    {
      badPictures++;
    }
  else
    {
      otherErrors++;
    }
  fprintf(stderr, "X error %d (render base %d), request %d.%d, serial %lu\n",
    e->error_code, renderErrorBase, e->request_code, e->minor_code,
    e->serial);
  return 0;
}

/* Ends a running alert from a timer in the modal mode, once it is on screen:
 * -abortModal alone doesn't always end the run, so the timer repeats. */
@interface AlertEnder : NSObject
{
@public
  Display	*dpy;
  int		*margins;
  BOOL		seen;
}
@end

@implementation AlertEnder
- (void) tick: (NSTimer *)timer
{
  NSWindow	*panel = [NSApp modalWindow];

  if (seen == NO && panel != nil)
    {
      XWindowAttributes	a;

      seen = YES;
      XSync((Display *)[GSCurrentServer() serverDevice], False);
      if (XGetWindowAttributes(dpy,
	(Window)[GSCurrentServer() windowDevice: [panel windowNumber]], &a)
	&& a.depth == 32)
	{
	  (*margins)++;
	}
    }
  [NSApp abortModal];
  [NSApp postEvent: [NSEvent otherEventWithType: NSApplicationDefined
				       location: NSZeroPoint
				  modifierFlags: 0
				      timestamp: 0
				   windowNumber: 0
					context: nil
					subtype: 0
					  data1: 0
					  data2: 0]
	   atStart: NO];
}
@end

int
main(int argc, const char **argv)
{
  START_SET("closing a window with a shadow")

  Display		*dpy;
  Display		*serverDpy;
  pid_t			wm;
  pid_t			compositor;
  int			eventBase;
  int			i;
  int			margins = 0;
  BOOL			realWM;

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
  /* WINDOWTERM_REAL_WM: the display's own window and compositing manager,
     for comparing with a real one (GNOME Shell's). */
  realWM = (getenv("WINDOWTERM_REAL_WM") != NULL);
  if (realWM == NO
    && (XGetSelectionOwner(dpy, XInternAtom(dpy, "WM_S0", False)) != None
      || XGetSelectionOwner(dpy, fakeCompositorSelection(dpy)) != None))
    {
      SKIP("the display has a window or compositing manager of its own")
    }
  if (XRenderQueryExtension(dpy, &eventBase, &renderErrorBase) == False)
    {
      SKIP("the display has no Render extension")
    }
  wm = realWM ? 0 : fakeCSDWMStart(dpy);
  if (wm < 0)
    {
      SKIP("the test window manager did not start")
    }
  compositor = realWM ? 0 : fakeCompositorStart(dpy);
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
  serverDpy = (Display *)[GSCurrentServer() serverDevice];

  /* After the backend's own handler, which only logs. */
  XSetErrorHandler(countErrors);
  for (i = 0; i < 3; i++)
    {
      NSWindow		*window;
      XWindowAttributes	a;

      if (realWM || getenv("WINDOWTERM_ALERT") != NULL)
	{
	  /* As an app's alert goes: run modally, ended, then released. */
	  CREATE_AUTORELEASE_POOL(pool);
	  NSAlert	*alert = [[NSAlert alloc] init];
	  AlertEnder	*ender = [AlertEnder new];
	  NSTimer	*timer;

	  ender->dpy = dpy;
	  ender->margins = &margins;
	  [alert setMessageText: @"Delete?"];
	  [alert addButtonWithTitle: @"Delete"];
	  [alert addButtonWithTitle: @"Cancel"];
	  timer = [NSTimer timerWithTimeInterval: 0.5
					  target: ender
					selector: @selector(tick:)
					userInfo: nil
					 repeats: YES];
	  [[NSRunLoop currentRunLoop] addTimer: timer
				       forMode: NSModalPanelRunLoopMode];
	  [alert runModal];
	  [timer invalidate];
	  [[alert window] orderOut: nil];
	  RELEASE(alert);
	  RELEASE(ender);
	  RELEASE(pool);
	  spin(0.3);
	  XSync(serverDpy, False);
	  spin(0.1);
	  continue;
	}
      else
	{
	  window = [[NSWindow alloc]
	    initWithContentRect: NSMakeRect(100, 100, 200, 120)
		      styleMask: NSTitledWindowMask
			backing: NSBackingStoreBuffered
			  defer: NO];
	}
      [window orderFront: nil];
      [window display];
      [window flushWindow];
      spin(0.3);
      XSync(serverDpy, False);
      if (XGetWindowAttributes(dpy,
	(Window)[GSCurrentServer() windowDevice: [window windowNumber]], &a)
	&& a.depth == 32)
	{
	  margins++;
	}
      /* The surface goes when the pool that holds it drains, after the X
	 window. */
      {
	CREATE_AUTORELEASE_POOL(pool);

	/* As an alert's panel goes: ordered out, then released. */
	[window orderOut: nil];
	spin(0.2);
	[window release];
	RELEASE(pool);
      }
      spin(0.2);
      XSync(serverDpy, False);
      spin(0.1);
    }

  /* The gui lets go of a window's graphics state, and so of its surface,
     before it terminates the window.  A surface that no autorelease pool
     holds any more is freed then, before -termwindow:, which must not
     message it. */
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
      spin(0.3);
      [window orderOut: nil];
      spin(0.2);
      RELEASE(pool);
    }
    {
      CREATE_AUTORELEASE_POOL(pool);

      [window release];
      RELEASE(pool);
    }
    spin(0.2);
    XSync(serverDpy, False);
    spin(0.1);
  }
  PASS(YES, "a window whose surface was freed first closes");

#if HAVE_XFIXES
  PASS(margins == 3, "the windows have a margin, so the test means something");
#else
  /* Built without XFixes no window gets a margin (shadowmargin.m); the
     closes are still checked. */
  PASS(margins == 0, "without XFixes the windows have no margin");
#endif
  PASS(badPictures == 0, "closing them gives no RenderBadPicture (%d)",
    badPictures);
  PASS(otherErrors == 0, "nor any other X error (%d)", otherErrors);

  XSetErrorHandler(fakeCSDWMIgnoreError);
  if (realWM == NO)
    {
      fakeCompositorStop(dpy, compositor);
      fakeCSDWMStop(wm);
    }
  XCloseDisplay(dpy);

  END_SET("closing a window with a shadow")

  return 0;
}

#else

int
main(int argc, const char **argv)
{
  START_SET("closing a window with a shadow")
    SKIP("back is not built with the x11 server, XShape and XRender")
  END_SET("closing a window with a shadow")
  return 0;
}

#endif
