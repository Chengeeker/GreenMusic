"""Compile and render the production legacy glass shaders with SDK SwiftShader."""
import ctypes as C, os
from pathlib import Path
base=Path(os.environ['LOCALAPPDATA'])/'Android/Sdk/emulator/lib64/gles_swiftshader'
handle=os.add_dll_directory(str(base))
egl=C.WinDLL(str(base/'libEGL.dll'));gl=C.WinDLL(str(base/'libGLESv2.dll'))
def fn(lib,name,restype,args):
    f=getattr(lib,name);f.restype=restype;f.argtypes=args;return f
ptr=C.c_void_p;I=C.c_int;U=C.c_uint
get=fn(egl,'eglGetDisplay',ptr,[ptr]);init=fn(egl,'eglInitialize',U,[ptr,C.POINTER(I),C.POINTER(I)])
display=get(None);major=I();minor=I();assert init(display,C.byref(major),C.byref(minor))
choose=fn(egl,'eglChooseConfig',U,[ptr,C.POINTER(I),C.POINTER(ptr),I,C.POINTER(I)])
attributes=(I*15)(0x3040,0x40,0x3033,1,0x3024,8,0x3023,8,0x3022,8,0x3021,8,0x3038,0,0)
config=ptr();count=I();assert choose(display,attributes,C.byref(config),1,C.byref(count)) and count.value
create=fn(egl,'eglCreateContext',ptr,[ptr,ptr,ptr,C.POINTER(I)])
context=create(display,config,None,(I*3)(0x3098,3,0x3038));assert context
surface=fn(egl,'eglCreatePbufferSurface',ptr,[ptr,ptr,C.POINTER(I)])(display,config,(I*5)(0x3057,16,0x3056,16,0x3038));assert surface
assert fn(egl,'eglMakeCurrent',U,[ptr,ptr,ptr,ptr])(display,surface,surface,context)
createShader=fn(gl,'glCreateShader',U,[U]);source=fn(gl,'glShaderSource',None,[U,I,C.POINTER(C.c_char_p),C.POINTER(I)]);compileShader=fn(gl,'glCompileShader',None,[U]);shaderStatus=fn(gl,'glGetShaderiv',None,[U,U,C.POINTER(I)]);shaderLog=fn(gl,'glGetShaderInfoLog',None,[U,I,C.POINTER(I),C.c_char_p])
def shader(kind,text):
    sh=createShader(kind);body=C.c_char_p(text.encode());source(sh,1,C.byref(body),None);compileShader(sh);status=I();shaderStatus(sh,0x8B81,C.byref(status));log=C.create_string_buffer(65536);shaderLog(sh,len(log),None,log);assert status.value,log.value.decode();return sh
vertex=shader(0x8B31,'#version 300 es\nvoid main(){vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));gl_Position=vec4(p*2.0-1.0,0.0,1.0);}')
createProgram=fn(gl,'glCreateProgram',U,[]);attach=fn(gl,'glAttachShader',None,[U,U]);link=fn(gl,'glLinkProgram',None,[U]);programStatus=fn(gl,'glGetProgramiv',None,[U,U,C.POINTER(I)]);programLog=fn(gl,'glGetProgramInfoLog',None,[U,I,C.POINTER(I),C.c_char_p])
root=Path(__file__).resolve().parents[1]
programs = {}
for name in ('geometry','render'):
    text=(root/'app/src/main/assets/glass'/f'{name}.glsl').read_text(encoding='utf-8')
    fragment=shader(0x8B30,text);program=createProgram();attach(program,vertex);attach(program,fragment);link(program);status=I();programStatus(program,0x8B82,C.byref(status));log=C.create_string_buffer(65536);programLog(program,len(log),None,log);assert status.value,log.value.decode();print(name,'GLES 3 compilation/link passed')
    programs[name] = program
# Same texture orientation and two passes as LegacyGlass.kt.
width, height = 128, 64
textures, frames = (U * 3)(), (U * 2)()
uintp = C.POINTER(U)
fn(gl, 'glGenTextures', None, [I, uintp])(3, textures)
fn(gl, 'glGenFramebuffers', None, [I, uintp])(2, frames)
bind_texture = fn(gl, 'glBindTexture', None, [U, U])
param = fn(gl, 'glTexParameteri', None, [U, U, I])
upload = fn(gl, 'glTexImage2D', None, [U, I, I, I, I, I, U, U, ptr])
bind_frame = fn(gl, 'glBindFramebuffer', None, [U, U])
attach_texture = fn(gl, 'glFramebufferTexture2D', None, [U, U, U, U, I])
status_frame = fn(gl, 'glCheckFramebufferStatus', U, [U])
source_pixels = bytearray()
for y in range(height):
    pixel = (100 + y * 4, 56, 20, 255) if y < 32 else (24, 56, 100 + y * 2, 255)
    source_pixels.extend(bytes(pixel) * width)
source_buffer = (C.c_ubyte * len(source_pixels)).from_buffer(source_pixels)
for index, texture in enumerate(textures):
    bind_texture(0x0DE1, texture)
    for key, value in ((0x2801, 0x2601), (0x2800, 0x2601), (0x2802, 0x812F), (0x2803, 0x812F)):
        param(0x0DE1, key, value)
    upload(0x0DE1, 0, 0x1908, width, height, 0, 0x1908, 0x1401, source_buffer if index == 0 else None)
for index, frame in enumerate(frames):
    bind_frame(0x8D40, frame)
    attach_texture(0x8D40, 0x8CE0, 0x0DE1, textures[index + 1], 0)
    assert status_frame(0x8D40) == 0x8CD5
fn(gl, 'glViewport', None, [I, I, I, I])(0, 0, width, height)
use = fn(gl, 'glUseProgram', None, [U])
location = fn(gl, 'glGetUniformLocation', I, [U, C.c_char_p])
sampler = fn(gl, 'glUniform1i', None, [I, I])
active_texture = fn(gl, 'glActiveTexture', None, [U])
draw = fn(gl, 'glDrawArrays', None, [U, I, I])
read_pixels = fn(gl, 'glReadPixels', None, [I, I, I, I, U, U, ptr])
uniform = {n: fn(gl, f'glUniform{n}fv', None, [I, I, C.POINTER(C.c_float)]) for n in range(1, 5)}
active_texture(0x84C0)
bind_texture(0x0DE1, textures[0])
active_texture(0x84C1)
bind_texture(0x0DE1, textures[1])
values = {
    'uSize': (width, height), 'uGeometrySize': (width, height),
    'uBounds': (12, 12, 104, 40), 'uShapeSettings': (1, 1),
    'uGlassColor': (0, 0, 0, .4), 'uLightConfig': (0, 0, 1),
    'uBodyMode': (1,), 'uFrost': (0, 0, 0, 1), 'uEdgeConfig': (0, 1, 1 / 3, 0),
}

def render(ior):
    values['uOpticalProps'] = (ior, .008, 8, 1)
    for index, name in enumerate(('geometry', 'render')):
        program = programs[name]
        use(program)
        for key, value in values.items():
            uniform[len(value)](location(program, key.encode()), 1, (C.c_float * len(value))(*value))
        if name == 'render':
            sampler(location(program, b'uBackgroundTexture'), 0)
            sampler(location(program, b'uGeometryTexture'), 1)
        bind_frame(0x8D40, frames[index])
        draw(4, 0, 3)
    pixels = (C.c_ubyte * (width * height * 4))()
    read_pixels(0, 0, width, height, 0x1908, 0x1401, pixels)
    assert fn(gl, 'glGetError', U, [])() == 0
    return lambda x, y: tuple(pixels[4 * ((height - 1 - y) * width + x):][:4])

image = render(1.19)
flat = render(1)
assert image(3, 3)[3] == 0, 'Outside the pill must remain transparent'
top, bottom = image(64, 22), image(64, 42)
assert top[3] == 255 and top[0] > top[2] + 50, top
assert bottom[3] == 255 and bottom[2] > bottom[0] + 50, bottom
assert abs(image(64, 13)[0] - flat(64, 13)[0]) > 8, 'Refraction must displace the gradient near the rim'
print('GLES pixels passed: transparent mask, top/bottom sampling, refraction')
fn(egl,'eglMakeCurrent',U,[ptr,ptr,ptr,ptr])(display,None,None,None)
fn(egl,'eglDestroySurface',U,[ptr,ptr])(display,surface);fn(egl,'eglDestroyContext',U,[ptr,ptr])(display,context);fn(egl,'eglTerminate',U,[ptr])(display)
