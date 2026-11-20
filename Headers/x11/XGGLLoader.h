/* 	-*-ObjC-*- */
/* XGGLLoader - the GLX and GL functions of the x11 backend, loaded from
   libGL at run time

   Copyright (C) 2026 Free Software Foundation, Inc.

   This file is part of the GNUstep GUI Library.

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

#ifndef _GNUstep_H_XGGLLoader_
#define _GNUstep_H_XGGLLoader_

/* The backend doesn't link libGL: it opens libGL.so.1 (or glvnd's
   libGLX.so.0) the first time an app asks for an OpenGL pixel format or
   context, so an app that never uses OpenGL starts where no libGL is
   installed.  Include this after <GL/glx.h>; the calls below then go
   through XGGLFunctionTable, which XGGLLoad() fills.  */

/* Every GLX and GL function the x11 backend calls.  */
#define XG_GL_FUNCTIONS(F) \
  F(glXChooseFBConfig) \
  F(glXChooseVisual) \
  F(glXCopyContext) \
  F(glXCreateContext) \
  F(glXCreateNewContext) \
  F(glXCreateWindow) \
  F(glXDestroyContext) \
  F(glXDestroyWindow) \
  F(glXGetClientString) \
  F(glXGetConfig) \
  F(glXGetFBConfigAttrib) \
  F(glXGetVisualFromFBConfig) \
  F(glXMakeContextCurrent) \
  F(glXMakeCurrent) \
  F(glXQueryServerString) \
  F(glXSwapBuffers) \
  F(glGetError) \
  F(glGetString)

/* A pointer per function, typed by its <GL/glx.h> prototype.  */
#define XG_GL_POINTER(name) __typeof__(&name) p_##name;
typedef struct
{
  XG_GL_FUNCTIONS(XG_GL_POINTER)
} XGGLFunctions;
#undef XG_GL_POINTER

extern XGGLFunctions XGGLFunctionTable;

/* Loads libGL and every function above, once and thread safely.  Returns
   NO, and has logged one line saying why, when libGL or one of the
   functions isn't there; OpenGL is then unavailable.  */
extern BOOL XGGLLoad(void);

#define glXChooseFBConfig (XGGLFunctionTable.p_glXChooseFBConfig)
#define glXChooseVisual (XGGLFunctionTable.p_glXChooseVisual)
#define glXCopyContext (XGGLFunctionTable.p_glXCopyContext)
#define glXCreateContext (XGGLFunctionTable.p_glXCreateContext)
#define glXCreateNewContext (XGGLFunctionTable.p_glXCreateNewContext)
#define glXCreateWindow (XGGLFunctionTable.p_glXCreateWindow)
#define glXDestroyContext (XGGLFunctionTable.p_glXDestroyContext)
#define glXDestroyWindow (XGGLFunctionTable.p_glXDestroyWindow)
#define glXGetClientString (XGGLFunctionTable.p_glXGetClientString)
#define glXGetConfig (XGGLFunctionTable.p_glXGetConfig)
#define glXGetFBConfigAttrib (XGGLFunctionTable.p_glXGetFBConfigAttrib)
#define glXGetVisualFromFBConfig (XGGLFunctionTable.p_glXGetVisualFromFBConfig)
#define glXMakeContextCurrent (XGGLFunctionTable.p_glXMakeContextCurrent)
#define glXMakeCurrent (XGGLFunctionTable.p_glXMakeCurrent)
#define glXQueryServerString (XGGLFunctionTable.p_glXQueryServerString)
#define glXSwapBuffers (XGGLFunctionTable.p_glXSwapBuffers)
#define glGetError (XGGLFunctionTable.p_glGetError)
#define glGetString (XGGLFunctionTable.p_glGetString)

#endif
