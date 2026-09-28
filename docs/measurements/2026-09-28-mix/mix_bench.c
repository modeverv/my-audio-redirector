
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>
#define MAX_B 64
#define BATCH_CALLS 256
#define BATCHES 200
#define WARM_CALLS 4096
#define NOINLINE __attribute__((noinline))
static float planar[32*MAX_B],interleaved[20*MAX_B],left[MAX_B],right[MAX_B];
static mach_timebase_info_data_t tb;
static volatile double final_checksum;
static inline void observe(float*l,float*r){__asm__ __volatile__(""::"r"(l),"r"(r):"memory");}
static NOINLINE void premixed(int B,int inter,float bump){
 float g=.4f+bump,d=.001f/(float)B;
 for(int i=0;i<B;i++){left[i]=(inter?interleaved[i*20]:planar[i])*g;right[i]=(inter?interleaved[i*20+1]:planar[MAX_B+i])*g;g+=d;}
}
static NOINLINE void mono(int B,int N,int inter,float bump){
 memset(left,0,B*sizeof(float));memset(right,0,B*sizeof(float));
 for(int c=0;c<N;c++){
  float gl=(.35f+.002f*c)/N+bump,gr=(.25f+.003f*c)/N+bump,dl=.001f/(B*N),dr=-.0007f/(B*N);
  for(int i=0;i<B;i++){float x=inter?interleaved[i*20+c]:planar[c*MAX_B+i];left[i]+=x*gl;right[i]+=x*gr;gl+=dl;gr+=dr;}
 }
}
static NOINLINE void stereo(int B,int N,float bump){
 memset(left,0,B*sizeof(float));memset(right,0,B*sizeof(float));
 for(int c=0;c<N;c++){
  float g=(.4f+.002f*c)/N+bump,d=.001f/(B*N);
  for(int i=0;i<B;i++){left[i]+=planar[2*c*MAX_B+i]*g;right[i]+=planar[(2*c+1)*MAX_B+i]*g;g+=d;}
 }
}
static NOINLINE void dispatch(int kind,int B,int N,int inter,float bump){
 if(kind==0)premixed(B,inter,bump);else if(kind==1)mono(B,N,inter,bump);else stereo(B,N,bump);
}
static int cmp(const void*a,const void*b){double x=*(const double*)a,y=*(const double*)b;return (x>y)-(x<y);}
static double verify(int kind,int B,int N,int inter){
 dispatch(kind,B,N,inter,0);double maxerr=0;
 for(int i=0;i<B;i++){
  double l=0,r=0;
  if(kind==0){float g0=.4f,d=.001f/B;double g=g0+(double)i*d;l=(inter?interleaved[i*20]:planar[i])*g;r=(inter?interleaved[i*20+1]:planar[MAX_B+i])*g;}
  else for(int c=0;c<N;c++){
   if(kind==1){float gl=(.35f+.002f*c)/N,gr=(.25f+.003f*c)/N,dl=.001f/(B*N),dr=-.0007f/(B*N);float x=inter?interleaved[i*20+c]:planar[c*MAX_B+i];l+=x*(gl+(double)i*dl);r+=x*(gr+(double)i*dr);}
   else {float g=(.4f+.002f*c)/N,d=.001f/(B*N);l+=planar[2*c*MAX_B+i]*(g+(double)i*d);r+=planar[(2*c+1)*MAX_B+i]*(g+(double)i*d);}
  }
  double e=fmax(fabs(l-left[i]),fabs(r-right[i]));if(e>maxerr)maxerr=e;
 }
 if(maxerr>2e-6){fprintf(stderr,"verification failed %.9g\n",maxerr);exit(2);}return maxerr;
}
static void run(int kind,int B,int N,int inter){
 double err=verify(kind,B,N,inter),elapsed[BATCHES],sum=0,checksum=0;
 for(int k=0;k<WARM_CALLS;k++){dispatch(kind,B,N,inter,(float)(k&15)*.00001f);observe(left,right);}
 for(int b=0;b<BATCHES;b++){
  uint64_t start=mach_absolute_time();
  for(int k=0;k<BATCH_CALLS;k++){dispatch(kind,B,N,inter,(float)(k&15)*.00001f);observe(left,right);}
  uint64_t end=mach_absolute_time();double us=(double)(end-start)*tb.numer/tb.denom/1000./BATCH_CALLS;elapsed[b]=us;sum+=us;
  for(int i=0;i<B;i++)checksum+=(i+1)*(left[i]+.61803398875*right[i]);
 }
 final_checksum+=checksum;qsort(elapsed,BATCHES,sizeof(double),cmp);
 printf("%s,%s,%d,%d,%d,%d,%d,%.9f,%.9f,%.9f,%.9f,%.9f,%.9g,%.9g\n",kind==0?"premixed":kind==1?"mono_to_stereo":"stereo_routes",inter?"interleaved20":"planar",B,N,kind==2?2*N:kind==1?N:2,BATCHES,BATCH_CALLS,sum/BATCHES,elapsed[BATCHES/2],elapsed[(BATCHES*99)/100],elapsed[0],elapsed[BATCHES-1],err,checksum);
}
int main(void){
 mach_timebase_info(&tb);uint32_t rng=0x12345678u;
 for(int c=0;c<32;c++)for(int i=0;i<MAX_B;i++){rng=1664525u*rng+1013904223u;planar[c*MAX_B+i]=((float)((rng>>8)&0xFFFFFF)/16777216.f-.5f)*.2f;if(c<20)interleaved[i*20+c]=planar[c*MAX_B+i];}
 puts("case,layout,block_frames,logical_inputs,scalar_input_channels,batches,calls_per_batch,mean_us_per_block,p50_batch_amortized_us_per_block,p99_batch_amortized_us_per_block,min_batch_amortized_us_per_block,max_batch_amortized_us_per_block,max_abs_reference_error,checksum");
 int ns[]={2,8,16,20};for(int B=32;B<=64;B*=2){run(0,B,1,0);run(0,B,1,1);for(int j=0;j<4;j++){run(1,B,ns[j],0);run(1,B,ns[j],1);}run(2,B,8,0);run(2,B,16,0);}
 fprintf(stderr,"checksum %.12g\n",final_checksum);return 0;
}
