/* A compositing manager for the tests of windows with an alpha channel,
 * forked by the test that needs one.
 *
 * It only owns the _NET_WM_CM_S0 selection, which is how the backend tells
 * that a compositing manager runs; it composites nothing.  Killing it is
 * how the compositing manager goes away.  A test using it needs a display
 * with no compositing manager of its own (a private Xvfb).
 */
#ifndef FAKE_COMPOSITOR_H
#define FAKE_COMPOSITOR_H

#include <X11/Xlib.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

static Atom
fakeCompositorSelection(Display *dpy)
{
  return XInternAtom(dpy, "_NET_WM_CM_S0", False);
}

/* Runs in the child: owns the selection until killed. */
static void
fakeCompositorRun(void)
{
  Display	*dpy = XOpenDisplay(NULL);
  Window	owner;

  if (dpy == NULL)
    {
      _exit(1);
    }
  owner = XCreateSimpleWindow(dpy, DefaultRootWindow(dpy), -100, -100,
    1, 1, 0, 0, 0);
  XSetSelectionOwner(dpy, fakeCompositorSelection(dpy), owner, CurrentTime);
  XFlush(dpy);
  for (;;)
    {
      pause();
    }
}

/* Waits until a compositing manager runs, or no longer runs. */
static BOOL
fakeCompositorWait(Display *dpy, BOOL running)
{
  unsigned	i;

  for (i = 0; i < 100; i++)
    {
      if ((XGetSelectionOwner(dpy, fakeCompositorSelection(dpy)) != None)
	== running)
	{
	  return YES;
	}
      usleep(50000);
    }
  return NO;
}

/* Forks the compositing manager and waits until it runs: its pid, or -1. */
static pid_t
fakeCompositorStart(Display *dpy)
{
  pid_t	pid = fork();

  if (pid == 0)
    {
#ifdef __linux__
      /* Gone with the test, should it abort. */
      prctl(PR_SET_PDEATHSIG, SIGKILL);
#endif
      fakeCompositorRun();
      _exit(0);
    }
  if (pid < 0 || !fakeCompositorWait(dpy, YES))
    {
      if (pid > 0)
	{
	  kill(pid, SIGKILL);
	  waitpid(pid, NULL, 0);
	}
      return -1;
    }
  return pid;
}

/* Stops it and waits until the selection has no owner. */
static void
fakeCompositorStop(Display *dpy, pid_t pid)
{
  if (pid > 0)
    {
      kill(pid, SIGKILL);
      waitpid(pid, NULL, 0);
      fakeCompositorWait(dpy, NO);
    }
}

#endif
