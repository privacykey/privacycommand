import pathlib, shutil, sys
root=pathlib.Path(__file__).resolve().parent / 'output'
path=pathlib.Path(sys.argv[1]).resolve()
if not path.is_relative_to(root.resolve()): raise SystemExit('Refusing to remove results outside declared output')
if path.exists(): shutil.rmtree(path)
path.parent.mkdir(parents=True,exist_ok=True)
