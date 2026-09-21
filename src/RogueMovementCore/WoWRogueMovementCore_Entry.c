/* One Win32/x86 DLL entry. Do not duplicate movement/cast hooks in separate DLLs. */
#if !defined(_M_IX86) && !defined(__i386__)
#error WoW 1.12.1 build 5875 Windows x86 only
#endif
typedef void* RmcModule;
extern int __stdcall RogueMovementCore_MovementInit(RmcModule,unsigned long,void*);
extern int __stdcall RogueMovementCore_RearInit(RmcModule,unsigned int,void*);
int __stdcall DllMain(RmcModule module,unsigned long reason,void*reserved){
 if(reason==1ul){
  if(!RogueMovementCore_MovementInit(module,reason,reserved))return 0;
  if(!RogueMovementCore_RearInit(module,(unsigned int)reason,reserved)){
   RogueMovementCore_MovementInit(module,0ul,reserved);return 0;
  }
  return 1;
 }
 if(reason==0ul){
  RogueMovementCore_RearInit(module,0u,reserved);
  RogueMovementCore_MovementInit(module,0ul,reserved);
 }
 return 1;
}
