/* -*- mode:ObjC -*-
   XGGLLoader - load libGL at run time for the x11 backend's OpenGL support

   Copyright (C) 2026 Free Software Foundation, Inc.

   This file is part of the GNU Objective C User Interface Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; see the file COPYING.LIB.
   If not, see <http://www.gnu.org/licenses/> or write to the
   Free Software Foundation, 51 Franklin Street, Fifth Floor,
   Boston, MA 02110-1301, USA.
*/

#include "config.h"

#ifdef HAVE_GLX

#include <Foundation/NSString.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include "x11/XGOpenGL.h"

XGGLFunctions XGGLFunctionTable;

static pthread_once_t loadOnce = PTHREAD_ONCE_INIT;
static BOOL loaded = NO;

typedef void (*(*GetProcAddressFn)(const GLubyte *))(void);

/* Loads every function from one library; returns the name of the first
   one missing, or NULL.  glvnd's libGLX.so.0 has the GLX functions only,
   so the GL ones are asked of glXGetProcAddressARB when the library
   doesn't export them.  */
static const char *
loadFunctions(void *library)
{
  GetProcAddressFn getProcAddress
    = (GetProcAddressFn)dlsym(library, "glXGetProcAddressARB");
  void *f;

#define XG_GL_LOAD(name) \
  f = dlsym(library, #name); \
  if (f == NULL && getProcAddress != NULL && strncmp(#name, "glX", 3) != 0) \
    { \
      f = (void *)getProcAddress((const GLubyte *)#name); \
    } \
  if (f == NULL) \
    { \
      return #name; \
    } \
  XGGLFunctionTable.p_##name = (__typeof__(XGGLFunctionTable.p_##name))f;

  XG_GL_FUNCTIONS(XG_GL_LOAD)
#undef XG_GL_LOAD
  return NULL;
}

static void
loadGL(void)
{
  static const char *libraries[] = { "libGL.so.1", "libGLX.so.0" };
  char reason[512] = "";
  unsigned i;

  for (i = 0; i < sizeof(libraries) / sizeof(libraries[0]); i++)
    {
      /* Never closed: libGL can't be unloaded safely, and an app that
         links libGL itself gets the same copy back.  */
      void *library = dlopen(libraries[i], RTLD_NOW | RTLD_LOCAL);
      const char *error;
      size_t used = strlen(reason);

      if (library == NULL)
        {
          error = dlerror();
        }
      else if ((error = loadFunctions(library)) == NULL)
        {
          loaded = YES;
          return;
        }
      else
        {
          memset(&XGGLFunctionTable, 0, sizeof(XGGLFunctionTable));
        }
      snprintf(reason + used, sizeof(reason) - used, "%s%s%s%s",
               used ? "; " : "", library ? libraries[i] : "",
               library ? " has no " : "", error ? error : libraries[i]);
    }
  NSLog(@"OpenGL is unavailable, NSOpenGLPixelFormat and NSOpenGLContext"
        @" give nil: %s", reason);
}

BOOL
XGGLLoad(void)
{
  pthread_once(&loadOnce, loadGL);
  return loaded;
}

#endif /* HAVE_GLX */
