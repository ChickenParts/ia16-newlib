from pathlib import Path
import subprocess,json,os,hashlib,argparse,shutil
source=Path(__file__).resolve().parent
repo=source.parents[3]
parser=argparse.ArgumentParser(description='Run the DOS near-data emulated TLS compiler/runtime ABI oracle')
parser.add_argument('--tool-root', type=Path, required=True, help='LLVM build/install root containing bin/')
parser.add_argument('--out', type=Path, required=True, help='New output directory')
args=parser.parse_args()
b=args.tool_root.resolve()/'bin'
r=args.out.resolve()
r.mkdir(parents=True, exist_ok=False)
for name in ['probe.c','allocator.c','boot.asm','start.asm','runtime.ld']:
 shutil.copy2(source/name,r/name)
env=dict(os.environ,TMPDIR=str(r))
def run(cmd):return subprocess.run(list(map(str,cmd)),cwd=r,env=env,check=True,capture_output=True,text=True,timeout=60)
run(['nasm','-f','bin','boot.asm','-o','boot.bin']);run(['nasm','-f','elf32','start.asm','-o','start.o'])
rows=[]
for model in ['tiny','small']:
 for opt in ['0','2','z']:
  for kind in (['positive','negative','oom'] if model=='small' and opt=='2' else ['positive']):
   lane=r/(model+'-O'+opt+'-'+kind);lane.mkdir(exist_ok=False)
   flags=['--target=ia16-none-elf','-march=8086','-mmemory-model='+model,'-std=gnu17','-O'+opt,'-ffreestanding','-fno-builtin']
   run([b/'clang',*flags,'-femulated-tls','-DNEGATIVE='+str(int(kind=='negative')),'-c','probe.c','-o',lane/'probe.o'])
   run([b/'clang',*flags,'-DFAIL_ALLOC='+str(int(kind=='oom')),'-c','allocator.c','-o',lane/'allocator.o'])
   run([b/'clang',*flags,'-nostdlibinc','-isystem',repo/'newlib/libc/machine/ia16','-isystem',repo/'newlib/libc/include','-c',repo/'libgloss/ia16/dos-emutls.c','-o',lane/'emutls.o'])
   desc=run([b/'llvm-readobj','--sections','--relocations',lane/'probe.o']).stdout
   (lane/'readobj.txt').write_text(desc)
   assert 'SHF_TLS' not in desc and 'R_386_TLS' not in desc,'native TLS survived'
   run([b/'ld.lld','-m','elf_ia16','-T','runtime.ld','start.o',lane/'probe.o',lane/'allocator.o',lane/'emutls.o','-o',lane/'runtime.elf'])
   run([b/'llvm-objcopy','-O','binary',lane/'runtime.elf',lane/'runtime.bin'])
   payload=(lane/'runtime.bin').read_bytes();assert len(payload)<=120*512
   (lane/'runtime.img').write_bytes(((r/'boot.bin').read_bytes()+payload).ljust(1474560,b'\0'))
   expected=3 if kind=='negative' else 67 if kind=='oom' else 33
   for launch in range(2 if kind=='positive' else 1):
    cmd=['qemu-system-i386','-display','none','-monitor','none','-serial','none','-no-reboot','-boot','a','-nic','none','-device','isa-debug-exit,iobase=0xf4,iosize=0x04','-drive',f'file={lane}/runtime.img,format=raw,if=floppy']
    p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=15)
    row={'lane':lane.name,'launch':launch,'expected':expected,'exit':p.returncode,'image_sha256':hashlib.sha256((lane/'runtime.img').read_bytes()).hexdigest()};rows.append(row);(r/'results.json').write_text(json.dumps(rows,indent=2));print(row,flush=True);assert p.returncode==expected,p.stderr
