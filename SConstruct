import os

godot_cpp_dir = ARGUMENTS.get("godot_cpp_dir", os.environ.get("GODOT_CPP_DIR", ""))
if not godot_cpp_dir:
    raise ValueError("set GODOT_CPP_DIR to a job-local godot-cpp checkout")
if os.path.isabs(godot_cpp_dir):
    godot_cpp_dir = os.path.relpath(godot_cpp_dir, os.getcwd())

if not os.path.exists(os.path.join(godot_cpp_dir, "SConstruct")):
    raise FileNotFoundError(
        f"godot-cpp not found at {godot_cpp_dir}; set GODOT_CPP_DIR or pass godot_cpp_dir=..."
    )

env = SConscript(os.path.join(godot_cpp_dir, "SConstruct"))
env["ARCOM"] = "$AR $ARFLAGS $TARGET ${TEMPFILE('$SOURCES')}"
env.Append(CPPPATH=["src/native"])
if ARGUMENTS.get("platform", "") == "windows" and not env.get("use_mingw", False):
    env.Append(CCFLAGS=["/fp:strict"])
else:
    env.Append(CCFLAGS=["-ffp-contract=off"])
os.makedirs("bin", exist_ok=True)

sources = Glob("src/native/*.cpp")
library = env.SharedLibrary(f"bin/libaerosim_native{env['suffix']}{env['SHLIBSUFFIX']}", sources)
Default(library)
