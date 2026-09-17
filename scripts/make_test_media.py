"""Generate synthetic fixtures with real codecs; ffmpeg is a developer test tool only."""
from pathlib import Path
import subprocess
root=Path('HydroToneTests/Fixtures');root.mkdir(exist_ok=True)
def make(name,size,rate,codec='libx264',audio=False,hdr=None,duration='0.6'):
    path=root/(name+'.mov')
    if path.exists() and not hdr:return
    args=['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i',f'testsrc2=size={size}:rate={rate}:duration={duration}']
    if audio:args+=['-f','lavfi','-i',f'sine=frequency=880:sample_rate=48000:duration={duration}']
    args+=['-c:v',codec,'-threads','2','-preset','ultrafast']
    if codec=='libx265':args+=['-x265-params',('log-level=error:pools=2:colorprim=9:transfer='+('18' if hdr=='arib-std-b67' else '16')+':colormatrix=9') if hdr else 'log-level=error:pools=2','-tag:v','hvc1']
    if hdr:args+=['-pix_fmt','yuv420p10le','-color_primaries','bt2020','-color_trc',hdr,'-colorspace','bt2020nc']
    else:args+=['-pix_fmt','yuv420p','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709']
    if audio:args+=['-c:a','aac']
    args += ['-t',duration,str(path)]
    subprocess.run(args,check=True)
make('h264_1080_30_audio','1920x1080',30,audio=True)
make('hevc_1080_60','1920x1080',60,'libx265')
make('hevc_4k_24_audio','3840x2160',24,'libx265',audio=True)
make('hevc_4k_60','3840x2160',60,'libx265',duration='0.3')
make('hlg_10bit','1920x1080',30,'libx265',hdr='arib-std-b67')
make('pq_10bit','1920x1080',30,'libx265',hdr='smpte2084')
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(root/'h264_1080_30_audio.mov'),'-c','copy','-metadata:s:v:0','rotate=90',str(root/'portrait_audio.mov')],check=True)
print('Created',len(list(root.glob('*.mov'))),'fixtures')
