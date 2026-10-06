/* A window manager for the tests of windows with a shadow margin, forked by
 * the test that needs one.
 *
 * It announces itself as an EWMH window manager that knows
 * _GTK_FRAME_EXTENTS, which a window manager must for the backend to give a
 * window a margin, decorates nothing, maps what asks to be and grants
 * every configure request.  It never sets a window's state: a test sets
 * _NET_WM_STATE itself to play a maximize.  A test using it needs a display
 * with no window manager of its own (a private Xvfb).
 */
#ifndef FAKE_CSD_WINDOW_MANAGER_H
#define FAKE_CSD_WINDOW_MANAGER_H

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

/* The windows a test makes come and go, so a request naming one can fail
 * at any point.  Xlib's default handler exits.
 */
static int
fakeCSDWMIgnoreError(Display *d, XErrorEvent *e)
{
  return 0;
}

/* Runs in the child and never returns. */
static void
fakeCSDWMRun(void)
{
  Display	*dpy = XOpenDisplay(NULL);
  Window	root;
  Window	check;
  Atom		netCheck;
  Atom		supported[4];

  if (dpy == NULL)
    {
      _exit(1);
    }
  XSetErrorHandler(fakeCSDWMIgnoreError);
  root = DefaultRootWindow(dpy);
  netCheck = XInternAtom(dpy, "_NET_SUPPORTING_WM_CHECK", False);
  check = XCreateSimpleWindow(dpy, root, -100, -100, 1, 1, 0, 0, 0);
  XChangeProperty(dpy, check, netCheck, XA_WINDOW, 32, PropModeReplace,
    (unsigned char *)&check, 1);
  supported[0] = netCheck;
  supported[1] = XInternAtom(dpy, "_NET_WM_STATE", False);
  supported[2] = XInternAtom(dpy, "_GTK_FRAME_EXTENTS", False);
  supported[3] = XInternAtom(dpy, "_NET_FRAME_EXTENTS", False);
  XChangeProperty(dpy, root, XInternAtom(dpy, "_NET_SUPPORTED", False),
    XA_ATOM, 32, PropModeReplace, (unsigned char *)supported, 4);
  XSelectInput(dpy, root, SubstructureRedirectMask | SubstructureNotifyMask);
  /* Announced last, so a client that sees it finds the rest in place. */
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
      else if (e.type == ConfigureRequest)
	{
	  XWindowChanges	c;

	  c.x = e.xconfigurerequest.x;
	  c.y = e.xconfigurerequest.y;
	  c.width = e.xconfigurerequest.width;
	  c.height = e.xconfigurerequest.height;
	  XConfigureWindow(dpy, e.xconfigurerequest.window,
	    e.xconfigurerequest.value_mask & (CWX | CWY | CWWidth | CWHeight),
	    &c);
	}
      XFlush(dpy);
    }
}

/* Forks the window manager and waits until it has announced itself: its
 * pid, or -1.
 */
static pid_t
fakeCSDWMStart(Display *dpy)
{
  Atom		netCheck = XInternAtom(dpy, "_NET_SUPPORTING_WM_CHECK", False);
  pid_t		pid = fork();
  unsigned	i;

  if (pid == 0)
    {
#ifdef __linux__
      /* Gone with the test, should it abort. */
      prctl(PR_SET_PDEATHSIG, SIGKILL);
#endif
      fakeCSDWMRun();
      _exit(0);
    }
  if (pid < 0)
    {
      return -1;
    }
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
	      return pid;
	    }
	}
      usleep(50000);
    }
  kill(pid, SIGKILL);
  waitpid(pid, NULL, 0);
  return -1;
}

static void
fakeCSDWMStop(pid_t pid)
{
  if (pid > 0)
    {
      kill(pid, SIGKILL);
      waitpid(pid, NULL, 0);
    }
}

#endif
