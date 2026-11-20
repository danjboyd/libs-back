/* Tests for the child window that draws an NSOpenGLView on win32
 * (Source/win32/w32_GLcontext.m).
 *
 * The context draws into a native child window placed over the view, which
 * Windows paints whatever the GNUstep views around it draw.  So the child
 * window has to follow the view, and these check that -update and the
 * context's other methods make it:
 *  - hidden while the view or an ancestor is hidden, shown again after;
 *  - clipped to the view's visible rectangle (a window region) when part of
 *    the view is outside its ancestors' bounds, as in a scroll view;
 *  - destroyed as soon as the context lets go of it (-clearDrawable), not
 *    when an autorelease pool drains;
 *  - and that moving the context to another view keeps its OpenGL context
 *    (the old child window's WM_DESTROY used to delete the new one's).
 * Also that a pixel format made without NSOpenGLPFAWindow still draws to a
 * window, which some drivers (Mesa) refuse otherwise.
 *
 * The test calls the context's -update itself, so it checks the backend
 * whatever the gui does.  It needs OpenGL on the display and skips cleanly
 * without it, or when the win32 display server isn't built.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_win32) \
  && BUILD_SERVER == SERVER_win32

#import <AppKit/AppKit.h>
#include <windows.h>

static HWND
childWindowOf(NSWindow *window)
{
  return FindWindowEx((HWND)(intptr_t)[window windowNumber], NULL,
		      "NSOpenGLSubwindow", NULL);
}

static void
spin(void)
{
  [[NSRunLoop currentRunLoop]
    runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.2]];
}

static NSWindow *
makeWindow(void)
{
  NSWindow *window;

  window = AUTORELEASE([[NSWindow alloc]
    initWithContentRect: NSMakeRect(100, 100, 300, 300)
	      styleMask: NSTitledWindowMask
		backing: NSBackingStoreBuffered
		  defer: NO]);
  [window setReleasedWhenClosed: NO];
  [window orderFront: nil];
  return window;
}

/* A view with FRAME in CONTAINER, drawn so that its context attaches.  */
static NSOpenGLView *
addView(NSWindow *window, NSView *container, NSRect frame,
  NSOpenGLPixelFormat *format)
{
  NSOpenGLView *view;

  view = AUTORELEASE([[NSOpenGLView alloc] initWithFrame: frame
					      pixelFormat: format]);
  [container addSubview: view];
  [window display];
  spin();
  return view;
}

static void
checkSubwindow(NSOpenGLPixelFormat *format)
{
  NSWindow *window = makeWindow();
  NSView *container;
  NSOpenGLView *view;
  NSOpenGLContext *context;
  HWND child;
  RECT rect;
  RECT box;
  HRGN region;
  int kind;

  container = AUTORELEASE([[NSView alloc]
    initWithFrame: NSMakeRect(20, 20, 200, 200)]);
  [[window contentView] addSubview: container];
  view = addView(window, container, NSMakeRect(10, 10, 100, 100), format);
  context = [view openGLContext];
  child = childWindowOf(window);

  PASS(child != NULL, "drawing an OpenGL view makes its child window");
  PASS(child != NULL && IsWindowVisible(child),
    "the child window is shown with the view");
  GetClientRect(child, &rect);
  PASS(rect.right - rect.left == 100 && rect.bottom - rect.top == 100,
    "the child window is the view's size");

  [container setHidden: YES];
  [context update];
  PASS(!IsWindowVisible(child),
    "-update hides the child window while an ancestor is hidden");
  [container setHidden: NO];
  [context update];
  PASS(IsWindowVisible(child),
    "-update shows it again when the ancestor is unhidden");

  /* Push the view half out of its container: only the part inside shows.  */
  [view setFrameOrigin: NSMakePoint(150, 10)];
  [context update];
  region = CreateRectRgn(0, 0, 0, 0);
  kind = GetWindowRgn(child, region);
  GetRgnBox(region, &box);
  DeleteObject(region);
  PASS(kind == SIMPLEREGION && box.left == 0 && box.right == 50
    && box.bottom - box.top == 100,
    "-update clips the child window to the view's visible rectangle "
    "(region %ld,%ld %ldx%ld)", box.left, box.top,
    box.right - box.left, box.bottom - box.top);

  [view setFrameOrigin: NSMakePoint(10, 10)];
  [context update];
  region = CreateRectRgn(0, 0, 0, 0);
  kind = GetWindowRgn(child, region);
  DeleteObject(region);
  PASS(kind == ERROR,
    "-update removes the clip when the whole view is visible again");

  /* Moved wholly out of sight, the window is hidden rather than given an
     empty region.  */
  [view setFrameOrigin: NSMakePoint(400, 10)];
  [context update];
  PASS(!IsWindowVisible(child),
    "-update hides the child window when none of the view is visible");
  [view setFrameOrigin: NSMakePoint(10, 10)];
  [context update];

  /* Run inside a pool that is still alive: the window must go now.  */
  {
    CREATE_AUTORELEASE_POOL(pool);

    [context clearDrawable];
    PASS(childWindowOf(window) == NULL && !IsWindow(child),
      "-clearDrawable destroys the child window at once");
    PASS([context view] == nil, "and the context has no view");
    DESTROY(pool);
  }

  /* Attach the context to the view again.  */
  [context setView: view];
  PASS([context view] == view && childWindowOf(window) != NULL,
    "-setView: attaches the context to a new child window");

  /* Attach it once more while it is attached, as the gui does when it
     draws a view whose context lost track of it.  Each child window's
     WM_CREATE gives the context a new WGL context; the old window must go
     before that, or its WM_DESTROY (whenever the old window object is
     freed: here, when the pool drains) deletes the new one.  */
  {
    CREATE_AUTORELEASE_POOL(pool);

    [context setView: view];
    DESTROY(pool);
  }
  [context makeCurrentContext];
  PASS([context CGLContextObj] != NULL
    && wglGetCurrentContext() == (HGLRC)[context CGLContextObj],
    "attaching the context again keeps a WGL context that can be made "
    "current");
  child = childWindowOf(window);
  PASS(child != NULL && FindWindowEx((HWND)(intptr_t)[window windowNumber],
				     child, "NSOpenGLSubwindow", NULL) == NULL,
    "and leaves only one child window");
  [NSOpenGLContext clearCurrentContext];
  [context clearDrawable];

  [window close];
}

static void
checkPixelFormatWithoutWindowAttribute(void)
{
  NSOpenGLPixelFormatAttribute attributes[] = {
    NSOpenGLPFADoubleBuffer,
    NSOpenGLPFAColorSize, 24,
    0
  };
  NSOpenGLPixelFormat *format;
  NSWindow *window;
  NSOpenGLView *view;
  HWND child;
  HDC dc;
  PIXELFORMATDESCRIPTOR pfd;
  int index;

  format = AUTORELEASE([[NSOpenGLPixelFormat alloc]
    initWithAttributes: attributes]);
  if (format == nil)
    {
      return;
    }
  window = makeWindow();
  view = addView(window, [window contentView],
    NSMakeRect(10, 10, 100, 100), format);
  child = childWindowOf(window);
  PASS([[view openGLContext] CGLContextObj] != NULL && child != NULL,
    "a pixel format without NSOpenGLPFAWindow still gives a window context");
  memset(&pfd, 0, sizeof(pfd));
  index = 0;
  if (child != NULL)
    {
      dc = GetDC(child);
      index = GetPixelFormat(dc);
      if (index > 0)
	{
	  DescribePixelFormat(dc, index, sizeof(pfd), &pfd);
	}
      ReleaseDC(child, dc);
    }
  PASS(index > 0 && (pfd.dwFlags & PFD_DRAW_TO_WINDOW) != 0,
    "its child window's pixel format draws to a window");
  [[view openGLContext] clearDrawable];
  [window close];
}

int
main(int argc, char **argv)
{
  CREATE_AUTORELEASE_POOL(arp);

  START_SET("win32 OpenGL view child window")

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
    {
      NSOpenGLPixelFormat *format = [NSOpenGLView defaultPixelFormat];

      if (format == nil)
	{
	  SKIP("No OpenGL pixel format available on this display")
	}
      checkSubwindow(format);
      checkPixelFormatWithoutWindowAttribute();
    }
  NS_HANDLER
    if ([[localException name] isEqualToString: @"SkipSet"])
      [localException raise];
    else
      {
	PASS(NO, "the OpenGL view checks raise no exception, but %s was "
	  "raised: %s", [[localException name] UTF8String],
	  [[localException reason] UTF8String]);
      }
  NS_ENDHANDLER

  END_SET("win32 OpenGL view child window")

  DESTROY(arp);
  return 0;
}

#else

int
main(int argc, char **argv)
{
  START_SET("win32 OpenGL view child window")
    SKIP("The win32 display server is not built")
  END_SET("win32 OpenGL view child window")
  return 0;
}

#endif
