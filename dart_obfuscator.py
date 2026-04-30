# 总流程逻辑在dart_obfuscator_readme.md里面进行描述
import os
import subprocess
import sys

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    
    print("=== Launching AST-based Dart Obfuscator ===")
    
    # We run the dart script
    cmd = ["dart", "run", "bin/dart_obfuscator.dart"]
    try:
        subprocess.run(cmd, cwd=script_dir, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error running dart obfuscator: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
