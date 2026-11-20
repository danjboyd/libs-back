/* Tests for the X window that draws an NSOpenGLView on X11
 * (Source/x11/XGGLContext.m).
 *
 * The context draws into a child X window placed over the view, which the X
 * server shows whatever the GNUstep views round it draw.  So the child window
 * has to follow the view, and these check, by asking the X server, that
 * -update and the context's other methods make it:
 *  - unmapped while the view or an ancestor is hidden, mapped again after;
 *  - clipped (a bounding shape) to the view's visible rectangle when part of
 *    the view is outside its ancestors' bounds, in a plain superview and in a
 *    scroll view, and drawn only there;
 *  - unmapped when none of the view is visible, or when the view has left
 *    its window;
 *  - destroyed as soon as the context lets go of it (-clearDrawable), not
 *    when an autorelease pool drains;
 *  - and that attaching the context to the view again keeps its GLX context
 *    and leaves one child window.
 *
 * The test calls the context's -update itself, so it checks the backend
 * whatever the gui does.  It needs GLX on the display (Xvfb has it, with
 * Mesa's llvmpipe) and skips cleanly without it, or when the x11 server, or
 * the backend's GLX support, isn't built.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_x11) \
  && BUILD_SERVER == SERVER_x11 && defined(HAVE_GLX) && defined(HAVE_XSHAPE)

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/shape.h>
#include <dlfcn.h>

/* The GL calls the test makes, looked up in the libGL the backend loaded,
 * so that the test links only what the other x11 tests do.  */
typedef void *(*GetCurrentContextFn)(void);
typedef void (*ClearColorFn)(float, float, float, float);
typedef void (*ClearFn)(unsigned int);
typedef void (*FinishFn)(void);

static void *
glFunction(const char *name)
{
  void *f = dlsym(RTLD_DEFAULT, name);

  if (f == NULL)
    {
      void *lib = dlopen("libGL.so.1", RTLD_LAZY | RTLD_NOLOAD);

      if (lib != NULL)
	{
	  f = dlsym(lib, name);
	}
    }
  return f;
}

static Display *
backendDisplay(void)
{
  return (Display *)[GSCurrentServer() serverDevice];
}

static Window
xWindowOf(NSWindow *window)
{
  return (Window)[GSCurrentServer() windowDevice: [window windowNumber]];
}

/* The child windows of WINDOW's X window, after the backend's requests have
 * reached the server.  Returns the number, and the last (topmost) in *LAST.  */
static unsigned int
childWindows(NSWindow *window, Window *last)
{
  Display *dpy = backendDisplay();
  Window root, parent, *children = NULL;
  unsigned int n = 0;

  XSync(dpy, False);
  *last = None;
  if (XQueryTree(dpy, xWindowOf(window), &root, &parent, &children, &n))
    {
      if (n > 0)
	{
	  *last = children[n - 1];
	}
      if (children != NULL)
	{
	  XFree(children);
	}
    }
  return n;
}

static int
mapState(Window w)
{
  XWindowAttributes a;

  XSync(backendDisplay(), False);
  if (w == None || !XGetWindowAttributes(backendDisplay(), w, &a))
    {
      return -1;
    }
  return a.map_state;
}

static BOOL
geometry(Window w, XWindowAttributes *a)
{
  XSync(backendDisplay(), False);
  return w != None && XGetWindowAttributes(backendDisplay(), w, a);
}

/* The bounding shape of W: the number of rectangles, the first in *BOX, and
 * whether a shape has been set at all.  */
static int
boundingShape(Window w, XRectangle *box, Bool *shaped)
{
  Display *dpy = backendDisplay();
  XRectangle *rects;
  int count = 0, ordering;
  Bool cShaped;
  int bx, by, cx, cy;
  unsigned int bw, bh, cw, ch;

  XSync(dpy, False);
  memset(box, 0, sizeof(*box));
  XShapeQueryExtents(dpy, w, shaped, &bx, &by, &bw, &bh,
		     &cShaped, &cx, &cy, &cw, &ch);
  rects = XShapeGetRectangles(dpy, w, ShapeBounding, &count, &ordering);
  if (rects != NULL)
    {
      if (count > 0)
	{
	  *box = rects[0];
	}
      XFree(rects);
    }
  return count;
}

static unsigned long
pixelAt(Window w, int x, int y)
{
  XImage *image;
  unsigned long pixel = 0;

  XSync(backendDisplay(), False);
  image = XGetImage(backendDisplay(), w, x, y, 1, 1, AllPlanes, ZPixmap);
  if (image != NULL)
    {
      pixel = XGetPixel(image, 0, 0) & 0xffffff;
      XDestroyImage(image);
    }
  return pixel;
}

static int
ignoreErrors(Display *d, XErrorEvent *e)
{
  return 0;
}

static int xErrors = 0;

static int
countErrors(Display *d, XErrorEvent *e)
{
  xErrors++;
  return 0;
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
  [window display];
  spin();
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

/* Fills the view's drawable with red.  */
static BOOL
fillRed(NSOpenGLContext *context)
{
  ClearColorFn clearColor = (ClearColorFn)glFunction("glClearColor");
  ClearFn clear = (ClearFn)glFunction("glClear");
  FinishFn finish = (FinishFn)glFunction("glFinish");

  if (clearColor == NULL || clear == NULL || finish == NULL)
    {
      return NO;
    }
  [context makeCurrentContext];
  clearColor(1.0, 0.0, 0.0, 1.0);
  clear(0x00004000 /* GL_COLOR_BUFFER_BIT */);
  [context flushBuffer];
  finish();
  XSync(backendDisplay(), False);
  return YES;
}

static void
checkSubwindow(NSOpenGLPixelFormat *format)
{
  GetCurrentContextFn getCurrent
    = (GetCurrentContextFn)glFunction("glXGetCurrentContext");
  NSWindow *window = makeWindow();
  NSView *container;
  NSOpenGLView *view;
  NSOpenGLContext *context;
  unsigned int before, n;
  Window child, other;
  XWindowAttributes a;
  XRectangle box;
  Bool shaped;
  int count;
  void *glxContext;
  /* X sizes are device pixels; views are in points.  */
  CGFloat sc = [window userSpaceScaleFactor];
  int px100 = 100 * sc;

  before = childWindows(window, &other);
  container = AUTORELEASE([[NSView alloc]
    initWithFrame: NSMakeRect(20, 20, 200, 200)]);
  [[window contentView] addSubview: container];
  view = addView(window, container, NSMakeRect(10, 10, 100, 100), format);
  context = [view openGLContext];
  n = childWindows(window, &child);

  PASS(n == before + 1, "drawing an OpenGL view makes its child X window");
  PASS(mapState(child) == IsViewable, "the child window is mapped with the view");
  PASS(geometry(child, &a) && a.width == px100 && a.height == px100,
    "the child window is the view's size (%dx%d)", a.width, a.height);

  [container setHidden: YES];
  [context update];
  PASS(mapState(child) == IsUnmapped,
    "-update unmaps the child window while an ancestor is hidden");
  [container setHidden: NO];
  [context update];
  PASS(mapState(child) == IsViewable,
    "-update maps it again when the ancestor is unhidden");

  [view setHidden: YES];
  [context update];
  PASS(mapState(child) == IsUnmapped,
    "-update unmaps the child window while the view is hidden");
  [view setHidden: NO];
  [context update];
  PASS(mapState(child) == IsViewable,
    "-update maps it again when the view is unhidden");

  /* Push the view half out of its container: only the part inside shows.  */
  [view setFrameOrigin: NSMakePoint(150, 10)];
  [context update];
  count = boundingShape(child, &box, &shaped);
  PASS(shaped && count == 1 && box.x == 0 && box.y == 0
    && box.width == (int)(50 * sc) && box.height == px100,
    "-update clips the child window to the view's visible rectangle "
    "(shape %d,%d %ux%u, %d rectangles)", box.x, box.y,
    box.width, box.height, count);
  PASS(mapState(child) == IsViewable && geometry(child, &a)
    && a.width == px100,
    "and keeps it mapped, at the view's size");

  /* Drawn only there: the X server clips the GL drawing to the shape.  */
  spin();
  if (fillRed(context))
    {
      Window top = xWindowOf(window);
      int cx, cy;
      Window ignored;

      XTranslateCoordinates(backendDisplay(), child, top, 0, 0, &cx, &cy,
			    &ignored);
      PASS(pixelAt(top, cx + 25 * sc, cy + 50 * sc) == 0xff0000,
	"the GL drawing shows in the visible part of the view");
      PASS(pixelAt(top, cx + 75 * sc, cy + 50 * sc) != 0xff0000,
	"and not in the part clipped off (pixel %06lx)",
	pixelAt(top, cx + 75 * sc, cy + 50 * sc));
      [NSOpenGLContext clearCurrentContext];
    }
  else
    {
      PASS(NO, "the test finds glClear in the backend's libGL");
    }

  [view setFrameOrigin: NSMakePoint(10, 10)];
  [context update];
  count = boundingShape(child, &box, &shaped);
  PASS(!shaped,
    "-update removes the clip when the whole view is visible again");

  /* Moved wholly out of sight, the window is unmapped rather than given an
     empty shape.  */
  [view setFrameOrigin: NSMakePoint(400, 10)];
  [context update];
  PASS(mapState(child) == IsUnmapped,
    "-update unmaps the child window when none of the view is visible");
  [view setFrameOrigin: NSMakePoint(10, 10)];
  [context update];
  PASS(mapState(child) == IsViewable, "and maps it when it is visible again");

  /* Run inside a pool that is still alive: the window must go now.  */
  {
    CREATE_AUTORELEASE_POOL(pool);
    XErrorHandler old;

    glxContext = [context CGLContextObj];
    [context clearDrawable];
    n = childWindows(window, &other);
    old = XSetErrorHandler(ignoreErrors);
    PASS(n == before && mapState(child) == -1,
      "-clearDrawable destroys the child window at once");
    XSync(backendDisplay(), False);
    XSetErrorHandler(old);
    PASS([context view] == nil, "and the context has no view");
    DESTROY(pool);
  }

  /* Attach the context to the view again.  */
  [context setView: view];
  n = childWindows(window, &child);
  PASS([context view] == view && n == before + 1
    && mapState(child) == IsViewable,
    "-setView: attaches the context to a new, mapped child window");

  /* Attach it once more while it is attached, as the gui does when it
     draws a view whose context lost track of it.  The old window and its
     GLX drawable must go, and the GLX context stay.  */
  {
    CREATE_AUTORELEASE_POOL(pool);

    [context setView: view];
    DESTROY(pool);
  }
  [context makeCurrentContext];
  PASS([context CGLContextObj] == glxContext && glxContext != NULL
    && getCurrent != NULL && getCurrent() == glxContext,
    "attaching the context again keeps its GLX context, which can be made "
    "current");
  n = childWindows(window, &child);
  PASS(n == before + 1 && mapState(child) == IsViewable,
    "and leaves only one child window, mapped");
  if (fillRed(context))
    {
      PASS(pixelAt(child, 50 * sc, 50 * sc) == 0xff0000,
	"the context draws into the new child window");
    }
  [NSOpenGLContext clearCurrentContext];

  /* A view leaving its window: the gui clears the context's drawable (with
     its own carry), or else the backend unmaps the window at -update.  */
  RETAIN(view);
  [view removeFromSuperview];
  if ([context view] != nil)
    {
      [context update];
    }
  n = childWindows(window, &other);
  PASS(n == before || mapState(child) == IsUnmapped,
    "no child window shows once the view has left its window");
  [container addSubview: view];
  RELEASE(view);
  [window display];
  spin();
  if ([context view] != view)
    {
      /* Without the gui carry, nothing attaches it again.  */
      [context setView: view];
    }
  [context update];
  n = childWindows(window, &child);
  PASS([context view] == view && n == before + 1
    && mapState(child) == IsViewable,
    "back in the window, the view's child window is mapped again");

  /* A scroll view: a tall document view, of which the clip view shows the
     part scrolled to.  */
  {
    NSScrollView *scroll;
    NSOpenGLView *doc;
    NSOpenGLContext *docContext;
    NSRect visible;
    unsigned int expectedY;

    /* Out of the window first: a view whose context has no drawable can't
       be drawn with a gui that hasn't the NSOpenGLView carries.  */
    [view removeFromSuperview];
    [context clearDrawable];
    scroll = AUTORELEASE([[NSScrollView alloc]
      initWithFrame: NSMakeRect(20, 20, 150, 150)]);
    [scroll setHasVerticalScroller: YES];
    doc = AUTORELEASE([[NSOpenGLView alloc]
      initWithFrame: NSMakeRect(0, 0, 100, 400) pixelFormat: format]);
    [scroll setDocumentView: doc];
    [[window contentView] addSubview: scroll];
    [doc scrollPoint: NSMakePoint(0, 100)];
    [window display];
    spin();
    docContext = [doc openGLContext];
    [docContext update];
    n = childWindows(window, &child);
    visible = [doc visibleRect];
    count = boundingShape(child, &box, &shaped);
    expectedY = (NSHeight([doc bounds]) - NSMaxY(visible)) * sc;
    PASS([docContext view] == doc && mapState(child) == IsViewable
      && geometry(child, &a) && a.width == px100 && a.height == 4 * px100,
      "a document view's child window is mapped at the document's size");
    PASS(shaped && count == 1 && box.x == 0 && box.y == expectedY
      && box.width == (int)(NSWidth(visible) * sc)
      && box.height == (int)(NSHeight(visible) * sc),
      "and clipped to the part the scroll view shows (shape %d,%d %ux%u, "
      "visible %s)", box.x, box.y, box.width, box.height,
      [NSStringFromRect(visible) UTF8String]);

    [doc scrollPoint: NSMakePoint(0, 250)];
    [docContext update];
    visible = [doc visibleRect];
    count = boundingShape(child, &box, &shaped);
    expectedY = (NSHeight([doc bounds]) - NSMaxY(visible)) * sc;
    PASS(shaped && count == 1 && box.y == expectedY
      && box.height == (int)(NSHeight(visible) * sc),
      "scrolling moves the clip with it (shape %d,%d %ux%u)",
      box.x, box.y, box.width, box.height);
    [docContext clearDrawable];
    [scroll removeFromSuperview];
  }

  /* Closing the window destroys its X window, and the X server the child
     window with it: the context must not ask anything of the dead windows
     (BadWindow, GLXBadWindow), and attaches again when the window is shown
     again.  */
  {
    XErrorHandler old;
    NSOpenGLView *closing;
    NSOpenGLContext *closingContext;

    [container addSubview: view];
    if ([context view] != view)
      {
        /* A gui without the NSOpenGLView carries makes the context current
           before attaching it, which raises.  */
        [context setView: view];
      }
    [window display];
    spin();
    closing = view;
    closingContext = [closing openGLContext];
    glxContext = [closingContext CGLContextObj];
    XSync(backendDisplay(), False);
    xErrors = 0;
    old = XSetErrorHandler(countErrors);
    [window close];
    spin();
    [closingContext update];
    XSync(backendDisplay(), False);
    PASS(xErrors == 0, "closing a window with an OpenGL view in it gives no "
      "X error (%d)", xErrors);

    xErrors = 0;
    [window orderFront: nil];
    [window display];
    spin();
    [closingContext update];
    n = childWindows(window, &child);
    /* Errors aren't counted here: libs-back master's own window
       re-creation gives one (ConfigureWindow), with no OpenGL view.  */
    PASS([closingContext view] == closing
      && n == before + 1 && mapState(child) == IsViewable
      && [closingContext CGLContextObj] == glxContext,
      "shown again, the view's context attaches to a new child window and "
      "keeps its GLX context (%d errors)", xErrors);
    if (fillRed(closingContext))
      {
	PASS(pixelAt(child, 10, 10) == 0xff0000,
	  "and draws into it");
      }
    [NSOpenGLContext clearCurrentContext];

    xErrors = 0;
    [closingContext clearDrawable];
    [window close];
    spin();
    XSync(backendDisplay(), False);
    PASS(xErrors == 0, "clearing the drawable and closing gives no X error "
      "(%d)", xErrors);
    XSetErrorHandler(old);
  }
}

int
main(int argc, char **argv)
{
  CREATE_AUTORELEASE_POOL(arp);

  START_SET("x11 OpenGL view child window")

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
    {
      NSOpenGLPixelFormat *format = [NSOpenGLView defaultPixelFormat];

      if (format == nil)
	{
	  SKIP("No OpenGL pixel format available on this display")
	}
      checkSubwindow(format);
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

  END_SET("x11 OpenGL view child window")

  DESTROY(arp);
  return 0;
}

#else

int
main(int argc, char **argv)
{
  START_SET("x11 OpenGL view child window")
    SKIP("back is not built with the x11 server, GLX and the shape extension")
  END_SET("x11 OpenGL view child window")
  return 0;
}

#endif
