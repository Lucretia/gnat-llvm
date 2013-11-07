with Types; use Types;
with Atree; use Atree;
with Sinfo; use Sinfo;

with LLVM.Core; use LLVM.Core;

with GNATLLVM.Environment; use GNATLLVM.Environment;
with System; use System;
with Interfaces.C.Extensions; use Interfaces.C.Extensions;
with Uintp; use Uintp;

package GNATLLVM.Utils is

   function Param_Needs_Ptr
     (Arg : Node_Id) return Boolean;
   --  Returns true if Param needs to be passed by reference (pointer) rather
   --  than by value

   function Const_Int
     (T : Type_T; Value : Integer; Sign_Extend : Boolean := True)
      return Value_T
   is
     (Const_Int (T, unsigned_long_long (Value),
                 Sign_Extend => Boolean'Pos (Sign_Extend)));
   --  Return an LLVM value corresponding to Value

   function Const_Int
     (T : Type_T; Value : Uintp.Uint; Sign_Extend : Boolean := True)
      return Value_T
   is
     (Const_Int (T, Integer (UI_To_Int (Value)), Sign_Extend));
   --  Return an LLVM value corresponding to the universal int Value

   No_Value_T : constant Value_T := Value_T (Null_Address);
   --  Constant for the null llvm value

   type Pred_Mapping is record
      Signed : Int_Predicate_T;
      Unsigned : Int_Predicate_T;
      Real : Real_Predicate_T;
   end record;

   function Get_Preds (N : Node_Id) return Pred_Mapping is
     (case Nkind (N) is
         when N_Op_Eq => (Int_EQ, Int_EQ, Real_OEQ),
         when N_Op_Ne => (Int_NE, Int_NE, Real_ONE),
         when N_Op_Lt => (Int_SLT, Int_ULT, Real_OLT),
         when N_Op_Le => (Int_SLE, Int_ULE, Real_OLE),
         when N_Op_Gt => (Int_SGT, Int_UGT, Real_OGT),
         when N_Op_Ge => (Int_SGE, Int_UGE, Real_OGE),
         when others => (others => <>));

   type List_Iterator is array (Nat range <>) of Node_Id;
   type Entity_Iterator is array (Nat range <>) of Entity_Id;

   function Iterate (L : List_Id) return List_Iterator;
   --  Return an iterator on list L

   generic
      with function Get_First (Root : Entity_Id) return Entity_Id is <>;
      with function Get_Next (Elt : Entity_Id) return Entity_Id is <>;
   function Iterate_Entities (Root : Entity_Id) return Entity_Iterator;
   --  Likewise for the linked list of entities starting at Get_First (Root)

   function Get_Name (E : Entity_Id) return String;
   --  Return the name of an entity: Get_Name_String (Chars (E))

   procedure Discard (V : Value_T);

   function Is_Binary_Operator (Node : Node_Id) return Boolean;

   function Get_Stack_Save (Env : Environ) return Value_T;
   function Get_Stack_Restore (Env : Environ) return Value_T;

   procedure Dump_LLVM_Value (V : Value_T);
   --  Simple wrapper around LLVM.Core.Dump_Value. Gives an Ada name to this
   --  function that is usable in debugging sessions.

   procedure Dump_LLVM_Module (M : Module_T);
   --  Likewise, for LLVM.Core.Dump_Module

   procedure Dump_LLVM_Type (T : Type_T);
   --  Likewise, for LLVM.Core.Dump_Type

   function Index_In_List (N : Node_Id) return Natural;

   function LLVM_Type_Of (V : Value_T) return Type_T
   is (Type_Of (V));

end GNATLLVM.Utils;
