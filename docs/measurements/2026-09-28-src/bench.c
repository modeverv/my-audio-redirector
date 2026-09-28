
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>
#include <time.h>
#include <mach/mach_time.h>
#include "samplerate.h"
#define RATE 48000.0
#define CHANNELS 2
static mach_timebase_info_data_t tb;
static uint64_t ticks(void){return mach_absolute_time();}
static int cmp(const void*a,const void*b){double x=*(const double*)a,y=*(const double*)b;return (x>y)-(x<y);}
static void fail(int e){if(e){fprintf(stderr,"SRC_ERROR %s\n",src_strerror(e));exit(1);}}
static void delay(int type,double ratio,int block){
 int e=0;SRC_STATE*s=src_new(type,CHANNELS,&e);fail(e);float in[128],out[4096];long ni=0,no=0,first_in=-1,first_gen=0,first_full_in=-1,pk_idx=-1,pk_available=-1;double peak=0,lag_min=1e9,lag_max=-1e9;
 for(int z=0;z<8192/block;z++){
  for(int j=0;j<block;j++){in[j*2]=(ni+j==1024)?1.f:0.f;in[j*2+1]=in[j*2];}
  SRC_DATA d={0};d.data_in=in;d.data_out=out;d.input_frames=block;d.output_frames=2048;d.src_ratio=ratio;d.end_of_input=0;fail(src_process(s,&d));
  if(d.input_frames_used!=block){fprintf(stderr,"unexpected partial input\n");exit(2);}ni+=d.input_frames_used;
  if(d.output_frames_gen && first_in<0){first_in=ni;first_gen=d.output_frames_gen;}
  if(first_full_in<0 && no+d.output_frames_gen>=block)first_full_in=ni;
  for(long j=0;j<d.output_frames_gen;j++){double x=fabs(out[j*2]);if(x>peak){peak=x;pk_idx=no+j;pk_available=ni-1;}}
  no+=d.output_frames_gen;
  if(ni>2048){double lag=ni-no/ratio;if(lag<lag_min)lag_min=lag;if(lag>lag_max)lag_max=lag;}
 }
 printf("delay,%s,%.7f,%d,%ld,%d,%ld,%ld,%ld,%.6f,%.6f,%.9f\n",src_get_name(type),ratio,block,first_in,(int)first_gen,first_full_in,pk_idx,pk_available-1024,lag_min,lag_max,peak);
 src_delete(s);
}
static void cpu(int type,int block){
 enum{N=20000,WARM=3000};int e=0;SRC_STATE*s=src_new(type,2,&e);fail(e);float in[256],out[256];double times[N],sum=0;long generated=0;int short_calls=0;
 for(int j=0;j<256;j++)in[j]=(float)(.1*sin(j*.07));
 for(int k=-WARM;k<N;k++){
  SRC_DATA d={0};d.data_in=in;d.data_out=out;d.input_frames=block+2;d.output_frames=block;d.src_ratio=1.+.0001*sin(k*.003);d.end_of_input=0;
  uint64_t begin=ticks();fail(src_process(s,&d));uint64_t end=ticks();
  if(k>=0){times[k]=(double)(end-begin)*tb.numer/tb.denom/1000.;sum+=times[k];generated+=d.output_frames_gen;if(d.output_frames_gen<block)short_calls++;}
 }
 qsort(times,N,sizeof(double),cmp);printf("cpu,%s,%d,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%ld,%d\n",src_get_name(type),block,N,sum/N,times[N/2],times[(N*99)/100],times[(N*999)/1000],times[N-1],generated,short_calls);
 src_delete(s);
}
static void required(int type,double ratio,int target){
 int e=0;SRC_STATE*s=src_new(type,2,&e);fail(e);float in[2]={0,0},out[1024];int nin=0,nout=0;
 while(nout<target){SRC_DATA d={0};d.data_in=in;d.data_out=out;d.input_frames=1;d.output_frames=512;d.src_ratio=ratio;fail(src_process(s,&d));nin+=d.input_frames_used;nout+=d.output_frames_gen;if(nin>2000)exit(3);}
 printf("required,%s,%.7f,%d,%d,%d\n",src_get_name(type),ratio,target,nin,nout);src_delete(s);
}
int main(void){mach_timebase_info(&tb);
 puts(src_get_version());puts("delay,mode,output_per_input,block_frames,first_output_after_input_frames,first_call_output_frames,first_B_output_after_input_frames,impulse_peak_output_index,impulse_peak_available_input_delay_frames,steady_input_minus_output_over_ratio_min,steady_input_minus_output_over_ratio_max,impulse_peak");
 int modes[]={SRC_SINC_FASTEST,SRC_SINC_MEDIUM_QUALITY,SRC_SINC_BEST_QUALITY};double ratios[]={.9999,1.,1.0001};int blocks[]={1,32,64};
 for(int m=0;m<3;m++)for(int r=0;r<3;r++)for(int b=0;b<3;b++)delay(modes[m],ratios[r],blocks[b]);
 puts("required,mode,output_per_input,target_output_frames,minimum_input_frames,actual_output_frames");
 for(int m=0;m<3;m++)for(int r=0;r<3;r++)for(int b=1;b<3;b++)required(modes[m],ratios[r],blocks[b]);
 puts("cpu,mode,block_frames,iterations,mean_us,p50_us,p99_us,p99_9_us,max_us,total_output_frames,short_calls");
 for(int m=0;m<3;m++)for(int b=1;b<3;b++)cpu(modes[m],blocks[b]);
 return 0;
}
