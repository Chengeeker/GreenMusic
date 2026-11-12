package com.green.music.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.opengl.EGL14.*
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES30.*
import android.opengl.GLUtils
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Same two-pass shader on API 24–32. All GL calls stay on the surface's private worker. */
internal class LegacyGlass(private val context:Context) {
    private var display:EGLDisplay=EGL_NO_DISPLAY
    private var eglContext:EGLContext=EGL_NO_CONTEXT
    private var surface:EGLSurface=EGL_NO_SURFACE
    private var geometry=0;private var render=0
    private val textures=IntArray(3);private val frames=IntArray(2);private var width=0;private var height=0
    private fun initialize() {
        display=eglGetDisplay(EGL_DEFAULT_DISPLAY);check(eglInitialize(display,IntArray(1),0,IntArray(1),0))
        val configs=arrayOfNulls<EGLConfig>(1);val count=IntArray(1)
        check(eglChooseConfig(display,intArrayOf(EGL_RENDERABLE_TYPE,0x40,EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE),0,configs,0,1,count,0)&&count[0]>0)
        eglContext=eglCreateContext(display,configs[0],EGL_NO_CONTEXT,intArrayOf(EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE),0)
        surface=eglCreatePbufferSurface(display,configs[0],intArrayOf(EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE),0)
        check(eglMakeCurrent(display,surface,surface,eglContext))
        fun shader(type:Int,source:String):Int {val shader=glCreateShader(type);glShaderSource(shader,source);glCompileShader(shader);val status=IntArray(1);glGetShaderiv(shader,GL_COMPILE_STATUS,status,0);check(status[0]!=0){glGetShaderInfoLog(shader)};return shader}
        val vertex=shader(GL_VERTEX_SHADER,"#version 300 es\nvoid main(){vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));gl_Position=vec4(p*2.0-1.0,0.0,1.0);}")
        fun program(name:String):Int {
            val source=context.assets.open("glass/$name.glsl").bufferedReader().use{it.readText()}
            val fragment=shader(GL_FRAGMENT_SHADER,source);val id=glCreateProgram();glAttachShader(id,vertex);glAttachShader(id,fragment);glLinkProgram(id);val status=IntArray(1);glGetProgramiv(id,GL_LINK_STATUS,status,0);check(status[0]!=0){glGetProgramInfoLog(id)};glDeleteShader(fragment);return id
        }
        geometry=program("geometry");render=program("render");glDeleteShader(vertex);glGenTextures(3,textures,0);glGenFramebuffers(2,frames,0)
    }
    fun render(bitmap:Bitmap,values:Map<String,FloatArray>):Bitmap {
        if(display==EGL_NO_DISPLAY)initialize()
        if(width!=bitmap.width||height!=bitmap.height){width=bitmap.width;height=bitmap.height
            for(i in textures.indices){glBindTexture(GL_TEXTURE_2D,textures[i]);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,null)}
            for(i in frames.indices){glBindFramebuffer(GL_FRAMEBUFFER,frames[i]);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,textures[i+1],0);check(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE)}
        }
        glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,textures[0]);GLUtils.texSubImage2D(GL_TEXTURE_2D,0,0,0,bitmap)
        glViewport(0,0,width,height)
        fun pass(program:Int,frame:Int){glUseProgram(program);values.forEach{(name,v)->val loc=glGetUniformLocation(program,name);if(loc>=0)when(v.size){1->glUniform1fv(loc,1,v,0);2->glUniform2fv(loc,1,v,0);3->glUniform3fv(loc,1,v,0);4->glUniform4fv(loc,1,v,0)}};glBindFramebuffer(GL_FRAMEBUFFER,frame);glDrawArrays(GL_TRIANGLES,0,3)}
        pass(geometry,frames[0]);glUseProgram(render);glUniform1i(glGetUniformLocation(render,"uBackgroundTexture"),0);glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,textures[1]);glUniform1i(glGetUniformLocation(render,"uGeometryTexture"),1);pass(render,frames[1])
        val buffer=ByteBuffer.allocateDirect(width*height*4).order(ByteOrder.nativeOrder());glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,buffer);check(glGetError()==GL_NO_ERROR)
        val bottomUp=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888);bottomUp.copyPixelsFromBuffer(buffer);val output=Bitmap.createBitmap(bottomUp,0,0,width,height,Matrix().apply{preScale(1f,-1f)},false);if(output!==bottomUp)bottomUp.recycle();return output
    }
    fun close(){if(display!=EGL_NO_DISPLAY){glDeleteProgram(geometry);glDeleteProgram(render);glDeleteTextures(3,textures,0);glDeleteFramebuffers(2,frames,0);eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);eglDestroySurface(display,surface);eglDestroyContext(display,eglContext);eglTerminate(display);display=EGL_NO_DISPLAY}}
}
