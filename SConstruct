import os

godot_cpp_dir = ARGUMENTS.get("godot_cpp_dir", os.environ.get("GODOT_CPP_DIR", ".deps/godot-cpp"))

if not os.path.exists(os.path.join(godot_cpp_dir, "SConstruct")):
    raise FileNotFoundError(
        f"godot-cpp not found at {godot_cpp_dir}; set GODOT_CPP_DIR or pass godot_cpp_dir=..."
    )

env = SConscript(os.path.join(godot_cpp_dir, "SConstruct"))
env.Append(CPPPATH=["src/native"])
env.Append(CCFLAGS=["-ffp-contract=off"])
os.makedirs("bin", exist_ok=True)

sources = Glob("src/native/*.cpp")
library = env.SharedLibrary(f"bin/libaerosim_native{env['suffix']}{env['SHLIBSUFFIX']}", sources)
Default(library)
