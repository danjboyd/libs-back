/* Tests that the x11 backend loads libGL at run time, when an app first
 * asks for OpenGL (Source/x11/XGGLLoader.m), and doesn't link it:
 *  - starting the backend doesn't load libGL;
 *  - with libGL installed, asking for a pixel format loads it, and on a
 *    display with GLX gives a pixel format and an NSOpenGLView a context;
 *  - without libGL.so.1 and libGLX.so.0, OpenGL is unavailable and nothing
 *    else is: the backend reports no OpenGL classes, NSOpenGLPixelFormat and
 *    NSOpenGLContext give nil, an NSOpenGLView has no context, and its
 *    window shows, draws and closes.
 * Run it once with libGL installed and once without.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) \
  && BUILD_SERVER == SERVER_x11 && defined(HAVE_GLX)

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#include <X11/Xlib.h>
#include <dlfcn.h>

static void
spin(void)
{
  [[NSRunLoop currentRunLoop]
    runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.2]];
}

/* Whether a libGL is in the process already (RTLD_NOLOAD loads nothing).  */
static BOOL
libGLLoaded(void)
{
  return dlopen("libGL.so.1", RTLD_LAZY | RTLD_NOLOAD) != NULL
    || dlopen("libGLX.so.0", RTLD_LAZY | RTLD_NOLOAD) != NULL;
}

/* Whether the libraries the backend loads can be loaded.  */
static BOOL
libGLInstalled(void)
{
  return dlopen("libGL.so.1", RTLD_LAZY | RTLD_LOCAL) != NULL
    || dlopen("libGLX.so.0", RTLD_LAZY | RTLD_LOCAL) != NULL;
}

static BOOL
displayHasGLX(void)
{
  int opcode, event, error;

  return XQueryExtension((Display *)[GSCurrentServer() serverDevice], "GLX",
    &opcode, &event, &error);
}

static void
checkLoad(void)
{
  NSOpenGLPixelFormat *format;
  NSOpenGLView *view;
  NSWindow *window;
  BOOL loaded;
  BOOL installed;

  PASS(!libGLLoaded(), "starting the backend doesn't load libGL");

  format = [NSOpenGLView defaultPixelFormat];
  loaded = libGLLoaded();
  installed = libGLInstalled();

  if (installed)
    {
      PASS(loaded, "asking for a pixel format loads libGL");
      if (displayHasGLX())
	{
	  PASS(format != nil, "with libGL and GLX there is a pixel format");
	  PASS([GSCurrentServer() glContextClass] != Nil
	    && [GSCurrentServer() glPixelFormatClass] != Nil,
	    "with libGL the backend has OpenGL classes");
	}
    }
  else
    {
      NSOpenGLPixelFormatAttribute attributes[] = {
	NSOpenGLPFADoubleBuffer, NSOpenGLPFAColorSize, 24, 0
      };

      PASS(!loaded, "without libGL nothing loads one");
      PASS(format == nil, "without libGL there is no default pixel format");
      PASS([[NSOpenGLPixelFormat alloc] initWithAttributes: attributes] == nil,
	"without libGL NSOpenGLPixelFormat gives nil");
      PASS([GSCurrentServer() glContextClass] == Nil
	&& [GSCurrentServer() glPixelFormatClass] == Nil,
	"without libGL the backend reports no OpenGL classes");
      PASS([[NSOpenGLContext alloc] initWithFormat: format shareContext: nil]
	== nil, "without libGL NSOpenGLContext gives nil");
    }

  window = AUTORELEASE([[NSWindow alloc]
    initWithContentRect: NSMakeRect(100, 100, 200, 160)
	      styleMask: NSTitledWindowMask
		backing: NSBackingStoreBuffered
		  defer: NO]);
  [window setReleasedWhenClosed: NO];
  view = AUTORELEASE([[NSOpenGLView alloc]
    initWithFrame: NSMakeRect(10, 10, 100, 80)]);
  [[window contentView] addSubview: view];
  [window orderFront: nil];
  [window display];
  spin();
  PASS([window isVisible], "a window with an NSOpenGLView shows");
  if (format == nil)
    {
      PASS([view openGLContext] == nil,
	"without a pixel format the NSOpenGLView has no context");
    }
  else
    {
      PASS([view openGLContext] != nil, "the NSOpenGLView has a context");
    }
  [window close];
  spin();
  PASS(![window isVisible], "the window closes");
}

int
main(int argc, char **argv)
{
  CREATE_AUTORELEASE_POOL(arp);

  START_SET("x11 libGL loaded at run time")

  if (getenv("DISPLAY") == NULL || *getenv("DISPLAY") == '\0')
    {
      SKIP("no window server available")
    }

  NS_DURING
    [NSApplication sharedApplication];
  NS_HANDLER
    if ([[localException name] isEqualToString: @"SkipSet"])
      [localException raise];
    else
      {
	SKIP("The GNUstep backend could not start")
      }
  NS_ENDHANDLER

  NS_DURING
    checkLoad();
  NS_HANDLER
    if ([[localException name] isEqualToString: @"SkipSet"])
      [localException raise];
    else
      {
	PASS(NO, "the checks raise no exception, but %s was raised: %s",
	  [[localException name] UTF8String],
	  [[localException reason] UTF8String]);
      }
  NS_ENDHANDLER

  END_SET("x11 libGL loaded at run time")

  DESTROY(arp);
  return 0;
}

#else

int
main(int argc, char **argv)
{
  START_SET("x11 libGL loaded at run time")
    SKIP("back is not built with the x11 server and GLX")
  END_SET("x11 libGL loaded at run time")
  return 0;
}

#endif
