#!/usr/bin/env python3
"""Offline only; build official source in temp, with existing clang/cmake."""
from pathlib import Path
import tempfile, urllib.request, tarfile, io, subprocess, hashlib, shutil
w=Path(tempfile.mkdtemp(prefix="my-redirector-src-bench-"))
u="https://codeload.github.com/libsndfile/libsamplerate/tar.gz/refs/tags/0.2.2"
b=urllib.request.urlopen(u, timeout=30).read()
assert hashlib.sha256(b).hexdigest()=="16e881487f184250deb4fcb60432d7556ab12cb58caea71ef23960aec6c0405a"
(w/"source.tar.gz").write_bytes(b)
with tarfile.open(fileobj=io.BytesIO(b),mode="r:gz") as t: t.extractall(w,filter="data")
s=w/"libsamplerate-0.2.2"; build=w/"build"
subprocess.run(["cmake","-S",str(s),"-B",str(build),"-DCMAKE_BUILD_TYPE=Release","-DBUILD_SHARED_LIBS=OFF","-DBUILD_TESTING=OFF","-DLIBSAMPLERATE_EXAMPLES=OFF","-DLIBSAMPLERATE_INSTALL=OFF","-DCMAKE_POLICY_VERSION_MINIMUM=3.5"],check=True)
subprocess.run(["cmake","--build",str(build),"--parallel","2"],check=True)
shutil.copy2(Path(__file__).with_name("bench.c"),w/"bench.c")
subprocess.run(["clang","-O3","-DNDEBUG","-Wall","-Wextra","-I"+str(s/"include"),str(w/"bench.c"),str(build/"src/libsamplerate.a"),"-o",str(w/"bench")],check=True)
r=subprocess.run([str(w/"bench")],capture_output=True,text=True,check=True)
(w/"results.csv").write_text(r.stdout)
print(r.stdout); print("Artifacts:",w)
