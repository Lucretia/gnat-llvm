pragma Ada_2005;
pragma Style_Checks (Off);

pragma Warnings (Off); with Interfaces.C; use Interfaces.C; pragma Warnings (On);
with System;
with Interfaces.C.Strings;

package LLVM.Link_Time_Optimizer is

   type Lto_T_T is new System.Address;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/LinkTimeOptimizer.h:31

   type Lto_Status_T is 
     (LTO_UNKNOWN,
      LTO_OPT_SUCCESS,
      LTO_READ_SUCCESS,
      LTO_READ_FAILURE,
      LTO_WRITE_FAILURE,
      LTO_NO_TARGET,
      LTO_NO_WORK,
      LTO_MODULE_MERGE_FAILURE,
      LTO_ASM_FAILURE,
      LTO_NULL_OBJECT);
   pragma Convention (C, Lto_Status_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/LinkTimeOptimizer.h:35

   subtype Lto_Status_T_T is Lto_Status_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/LinkTimeOptimizer.h:48

   function Create_Optimizer return Lto_T_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/LinkTimeOptimizer.h:53
   pragma Import (C, Create_Optimizer, "llvm_create_optimizer");

   procedure Destroy_Optimizer (lto : Lto_T_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/LinkTimeOptimizer.h:54
   pragma Import (C, Destroy_Optimizer, "llvm_destroy_optimizer");

   function Read_Object_File
     (lto            : Lto_T_T;
      Input_Filename : String)
      return Lto_Status_T_T;
   function Read_Object_File_C
     (lto            : Lto_T_T;
      Input_Filename : Interfaces.C.Strings.chars_ptr)
      return Lto_Status_T_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/LinkTimeOptimizer.h:56
   pragma Import (C, Read_Object_File_C, "llvm_read_object_file");

   function Optimize_Modules
     (lto             : Lto_T_T;
      Output_Filename : String)
      return Lto_Status_T_T;
   function Optimize_Modules_C
     (lto             : Lto_T_T;
      Output_Filename : Interfaces.C.Strings.chars_ptr)
      return Lto_Status_T_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/LinkTimeOptimizer.h:58
   pragma Import (C, Optimize_Modules_C, "llvm_optimize_modules");

end LLVM.Link_Time_Optimizer;
