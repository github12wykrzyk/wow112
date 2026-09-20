/* WoW 1.12.1 build 5875 x86. Embedded rear-opener pose owner.
   The canonical PositionalSpoof source includes this file after its math and
   spell-classification helpers. No additional DLL or hook is installed. */
#ifndef W112_ROGUE_FACING_CORE_5875_H
#define W112_ROGUE_FACING_CORE_5875_H
typedef struct W112_RogueFacingPose {
 DWORD spell,candidate,target,guidLo,guidHi;
 float x,y,z,o;
 int valid;
} W112_RogueFacingPose;
static W112_RogueFacingPose g_rogueFacing;
static void W112_RogueFacingReset(void){
 g_rogueFacing.valid=0;g_rogueFacing.spell=0;g_rogueFacing.target=0;
}
/* One immutable XYZ/O snapshot per Backstab/Ambush candidate. */
static int W112_RogueFacingBegin(DWORD spell,DWORD candidate,DWORD target){
 float tx,ty,tz,to,a,x,y,z,o;
 if(!target||!isBehindSpell(spell))return 0;
 tx=*(float*)(target+UNIT_X);ty=*(float*)(target+UNIT_Y);
 tz=*(float*)(target+UNIT_Z);to=*(float*)(target+UNIT_O);
 if(tx!=tx||ty!=ty||tz!=tz||to!=to)return 0;
 a=candidateAngle(spell,candidate,to);
 x=tx+SPOOF_DISTANCE*fcos1(a);y=ty+SPOOF_DISTANCE*fsin1(a);
 z=tz;o=normAngle(a+PI_F);
 if(x!=x||y!=y||z!=z||o!=o)return 0;
 g_rogueFacing.valid=0;
 g_rogueFacing.spell=spell;g_rogueFacing.candidate=candidate;
 g_rogueFacing.target=target;
 g_rogueFacing.guidLo=*(DWORD*)(target+OBJ_GUID_LO);
 g_rogueFacing.guidHi=*(DWORD*)(target+OBJ_GUID_HI);
 g_rogueFacing.x=x;g_rogueFacing.y=y;g_rogueFacing.z=z;g_rogueFacing.o=o;
 g_rogueFacing.valid=1;return 1;
}
/* Refuse a stale pointer, switched target, stale candidate or recycled GUID. */
static int W112_RogueFacingRead(DWORD spell,DWORD candidate,DWORD target,
                               float *x,float *y,float *z,float *o){
 if(!g_rogueFacing.valid||!target||
    g_rogueFacing.spell!=spell||g_rogueFacing.candidate!=candidate||
    g_rogueFacing.target!=target||
    g_rogueFacing.guidLo!=*(DWORD*)(target+OBJ_GUID_LO)||
    g_rogueFacing.guidHi!=*(DWORD*)(target+OBJ_GUID_HI))return 0;
 *x=g_rogueFacing.x;*y=g_rogueFacing.y;
 *z=g_rogueFacing.z;*o=g_rogueFacing.o;return 1;
}
#endif
