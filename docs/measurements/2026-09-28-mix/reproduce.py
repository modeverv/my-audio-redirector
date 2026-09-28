#!/usr/bin/env python3
"""Build and run offline mixing benchmark using existing Apple clang."""
from pathlib import Path
import tempfile, subprocess, shutil
src=Path(__file__).with_name("mix_bench.c")
w=Path(tempfile.mkdtemp(prefix="my-redirector-mix-bench-"))
shutil.copy2(src,w/"mix_bench.c")
subprocess.run(["clang","-O3","-std=c11","-Wall","-Wextra",str(w/"mix_bench.c"),"-o",str(w/"mix_bench")],check=True)
r=subprocess.run([str(w/"mix_bench")],capture_output=True,text=True,check=True)
(w/"results.csv").write_text(r.stdout)
(w/"run-stderr.txt").write_text(r.stderr)
print(r.stdout);print(r.stderr);print("Artifacts:",w)
