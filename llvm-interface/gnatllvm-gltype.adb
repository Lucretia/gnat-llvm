------------------------------------------------------------------------------
--                             G N A T - L L V M                            --
--                                                                          --
--                     Copyright (C) 2013-2019, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Errout;     use Errout;
with Lib;        use Lib;
with Output;     use Output;
with Repinfo;    use Repinfo;
with Sinfo;      use Sinfo;
with Sprint;     use Sprint;
with Table;
with Uintp.LLVM; use Uintp.LLVM;

with LLVM.Core; use LLVM.Core;

with GNATLLVM.Conversions; use GNATLLVM.Conversions;
with GNATLLVM.Records;     use GNATLLVM.Records;
with GNATLLVM.Utils;       use GNATLLVM.Utils;

package body GNATLLVM.GLType is

   --  A GL_Type can be of various different kinds.  We list them here.

   type GT_Kind is
     (None,
      --  A so-far-unused entry

      Primitive,
      --  The actual type to perform computations in

      Dummy,
      --  A dummy type, made due to a chain of access types.  There are two
      --  cases, each handled differently.  The most common case is an access
      --  type pointing to a record.  In that case, we can make an opaque
      --  record that we can actually use for the record.  In that case,
      --  that's the same type that we really be used for the record, so the
      --  access type is "real" and the record type will only be considered
      --  "dummy" for a transitory period after which we'll change this entry
      --  to Primitive kind.
      --
      --  The other case is when we have an access to something else. In that
      --  case, we have to make a completely fake access type that points to
      --  something else.  In that case, we'll keep this entry around as a
      --  GL_Type because things will have that type and we'll have to convert
      --  as appropriate.

      Int_Alt,
      --  An integral type of a different width then the primitive type
      --  (either wider or narrower), but not a biased type.

      Biased,
      --  An integral type narrower than the primitive type and for which
      --  a bias is added value of the type to obtain a value of the
      --  primitive type.

      Padded,
      --  A record whose first field is the primitive type and the second
      --  is padding to make the record the proper length.  This can only
      --  be done if the primitive type is a native LLVM type.

      Byte_Array,
      --  An array of bytes (i8) whose length is the desired size of the
      --  GL_Type.  This should only be used when the primitive type is not
      --  a native LLVM type.

      Max_Size_Type,
      --  We're denoting that the maximum size of the type is used, but
      --  that maximum size is dynamic, so the LLVM type is actually that
      --  of the primitive type.  This also implies that the LLVM type is
      --  non-native.

      Aligning);
      --  The same LLVM type as for the primitive type, but recorded to
      --  indicate that we need to align it differently.  This occurs
      --  when the primitive type is not a native LLVM type or when we're
      --  just changing the alignment and not type.

   --  Define the fields in the table for GL_Type's

   type GL_Type_Info_Base is record
      GNAT_Type : Entity_Id;
      --  GNAT type

      LLVM_Type : Type_T;
      --  LLVM type used for this alternative

      Next      : GL_Type;
      --  If Present, link to next alternative

      Size      : GL_Value;
      --  If Present, size of this alternative in bytes

      Alignment : GL_Value;
      --  If Present, alignment of this alternative in bytes

      Bias      : GL_Value;
      --  If Present, the amount of bias for integral types

      Max_Size  : Boolean;
      --  If True, this corresponds to the maxumum size of an unconstrained
      --  variant record with default discriminant values;

      Kind      : GT_Kind;
      --  Says what type of alternative type this is

      Default   : Boolean;
      --  Marks the default GL_Type

   end record;
   --  We want to put a Predicate on this, but can't, so we need to make
   --  a subtype for that purpose.

   function GL_Type_Info_Is_Valid (GTI : GL_Type_Info_Base) return Boolean;
   --  Return whether GT is a valid GL_Type or not

   subtype GL_Type_Info is GL_Type_Info_Base
     with Predicate => GL_Type_Info_Is_Valid (GL_Type_Info);
   --  Subtype used by everybody except validation function

   function GL_Type_Info_Is_Valid_Int (GTI : GL_Type_Info_Base) return Boolean;
   --  Internal version of GL_Value_Is_Valid

   package GL_Type_Table is new Table.Table
     (Table_Component_Type => GL_Type_Info,
      Table_Index_Type     => GL_Type'Base,
      Table_Low_Bound      => GL_Type_Low_Bound,
      Table_Initial        => 2000,
      Table_Increment      => 200,
      Table_Name           => "GL_Type_Table");

   procedure Next (GT : in out GL_Type)
     with Pre => Present (GT);

   function Get_Or_Create_GL_Type
     (TE : Entity_Id; Create : Boolean) return GL_Type
     with Pre  => Is_Type_Or_Void (TE),
     Post => not Create or else Present (Get_Or_Create_GL_Type'Result);

   function Convert_Int (V : GL_Value; GT : GL_Type) return GL_Value
     with Pre  => Is_Data (V) and then Is_Discrete_Or_Fixed_Point_Type (V)
                  and then Is_Discrete_Or_Fixed_Point_Type (GT)
                  and then Full_Etype (Related_Type (V)) = Full_Etype (GT),
          Post => Related_Type (Convert_Int'Result) = GT;
   --  Convert V, which is of one integral type, to GT, an alternative
   --  of that type.

   function Make_GT_Alternative_Internal
     (GT        : GL_Type;
      Size      : Uint;
      Align     : Uint;
      For_Type  : Boolean;
      Max_Size  : Boolean;
      Is_Biased : Boolean) return GL_Type
     with Pre  => Present (GT),
          Post => Full_Etype (Make_GT_Alternative_Internal'Result)
                   = Full_Etype (GT);
   --  Internal version of Make_GT_Alternative to actually make the GL_Type

   ---------------------------
   -- GL_Type_Info_Is_Valid --
   ---------------------------

   function GL_Type_Info_Is_Valid (GTI : GL_Type_Info_Base) return Boolean is
      Valid : constant Boolean := GL_Type_Info_Is_Valid_Int (GTI);
   begin
      --  This function exists so a conditional breakpoint can be set at
      --  the following line to see the invalid value.  Otherwise, there
      --  seems no other reasonable way to get to see it.

      return Valid;
   end GL_Type_Info_Is_Valid;

   -------------------------------
   -- GL_Type_Info_Is_Valid_Int --
   -------------------------------

   function GL_Type_Info_Is_Valid_Int
     (GTI : GL_Type_Info_Base) return Boolean
   is
      TE : constant Entity_Id := GTI.GNAT_Type;
      T  : constant Type_T    := GTI.LLVM_Type;

   begin
      --  We have to be careful below and not call anything that will cause
      --  a validation of a GL_Value because that will cause mutual
      --  recursion with us.

      if GTI.Kind = None then
         return True;

      elsif not Is_Type_Or_Void (TE) or else No (T)
        or else (GTI.Size /= No_GL_Value
                   and then No (Is_A_Constant_Int (GTI.Size.Value)))
        or else (GTI.Alignment /= No_GL_Value
                   and then No (Is_A_Constant_Int (GTI.Alignment.Value)))
        or else (GTI.Bias /= No_GL_Value
                   and then No (Is_A_Constant_Int (GTI.Bias.Value)))
      then
         return False;
      end if;

      case GTI.Kind is
         when None  | Primitive | Aligning =>
            return True;
         when Dummy =>
            return Is_Record_Type (TE) or else Is_Access_Type (TE);
         when Int_Alt =>
            return Is_Discrete_Or_Fixed_Point_Type (TE);
         when Biased =>
            return GTI.Bias /= No_GL_Value and then Is_Discrete_Type (TE);
         when Padded =>
            return not Is_Nonnative_Type (TE)
              and then Get_Type_Kind (T) = Struct_Type_Kind;
         when Byte_Array =>
            return Is_Nonnative_Type (TE)
              and then Get_Type_Kind (T) = Array_Type_Kind;
         when Max_Size_Type =>
            return Is_Nonnative_Type (TE)
              and then Is_Unconstrained_Record (TE);
      end case;

   end GL_Type_Info_Is_Valid_Int;

   -------------
   -- Discard --
   -------------

   procedure Discard (GT : GL_Type) is
      pragma Unreferenced (GT);

   begin
      null;
   end Discard;

   ----------
   -- Next --
   ----------

   procedure Next (GT : in out GL_Type) is
   begin
      GT := GL_Type_Table.Table (GT).Next;
   end Next;

   -------------
   -- GT_Size --
   -------------

   function GT_Size (GT : GL_Type) return GL_Value is
     (GL_Type_Table.Table (GT).Size);

   -----------------
   -- Is_Max_Size --
   -----------------

   function Is_Max_Size (GT : GL_Type) return Boolean is
     (GL_Type_Table.Table (GT).Max_Size);

   ------------------
   -- GT_Alignment --
   ------------------

   function GT_Alignment (GT : GL_Type) return GL_Value is
     (GL_Type_Table.Table (GT).Alignment);

   ---------------------------
   -- Get_Or_Create_GL_Type --
   ---------------------------

   function Get_Or_Create_GL_Type
     (TE : Entity_Id; Create : Boolean) return GL_Type is
   begin
      return GT : GL_Type := Get_GL_Type (TE) do
         if No (GT) and then Create then
            Discard (Type_Of (TE));
            GT := Get_GL_Type (TE);
         end if;
      end return;
   end Get_Or_Create_GL_Type;

   ------------
   -- New_GT --
   ------------

   function New_GT (TE : Entity_Id) return GL_Type is
      GT : GL_Type;

   begin
      GL_Type_Table.Append ((GNAT_Type => TE,
                             LLVM_Type => No_Type_T,
                             Next      => Get_GL_Type (TE),
                             Size      => No_GL_Value,
                             Alignment => No_GL_Value,
                             Bias      => No_GL_Value,
                             Max_Size  => False,
                             Kind      => None,
                             Default   => False));

      GT := GL_Type_Table.Last;
      Set_GL_Type (TE, GT);
      return GT;
   end New_GT;

   -------------------------
   -- Make_GT_Alternative --
   -------------------------

   function Make_GT_Alternative
     (GT            : GL_Type;
      Def_Ident     : Entity_Id;
      Size          : Uint    := No_Uint;
      Align         : Uint    := No_Uint;
      For_Type      : Boolean := False;
      For_Component : Boolean := False;
      Max_Size      : Boolean := False;
      Is_Biased     : Boolean := False) return GL_Type
   is
      Out_GT    : constant GL_Type   :=
        Make_GT_Alternative_Internal (GT, Size, Align, For_Type, Max_Size,
                                      Is_Biased);
      Err_Ident : constant Entity_Id :=
        (if   Present (Def_Ident)
              and then Is_Packed_Array_Impl_Type (Def_Ident)
         then Original_Array_Type (Def_Ident) else Def_Ident);

   begin
      --  If this is an entity that comes from source, is in the unit being
      --  compiled, a size was specified, and we've made a padded type, set
      --  a warning saying how many bits are unused.

      if Present (Err_Ident) and then Comes_From_Source (Err_Ident)
        and then In_Extended_Main_Code_Unit (Err_Ident)
        and then Is_Padded_GL_Type (Out_GT)
        and then Size /= No_Uint
      then
         declare
            Align_V      : constant ULL      := Get_Type_Alignment (GT);
            Out_Sz       : constant GL_Value := Size_Const_Int (Size);
            In_Sz        : constant GL_Value := GT_Size (GT) * BPU;
            In_Sz_Align  : constant GL_Value :=
              Align_To (GT_Size (GT), 1, Align_V) * BPU;
            Pad_Sz       : constant GL_Value :=
              (if Present (In_Sz) then Out_Sz - In_Sz else No_GL_Value);
            Pad_Sz_Align : constant GL_Value :=
              (if   Present (In_Sz_Align) then Out_Sz - In_Sz_Align
               else No_GL_Value);
            Err_Node  : Entity_Id            := Empty;

         begin
            --  If we'd only give a message due to alignment of the type,
            --  skip.  But take the alignment padding into account when saying
            --  by how much we pad.

            if Present (Pad_Sz_Align) and then Pad_Sz_Align > 0 then
               if Ekind_In (Err_Ident, E_Component, E_Discriminant)
                 and then Present (Component_Clause (Err_Ident))
               then
                  Err_Node := Last_Bit (Component_Clause (Err_Ident));
               elsif Has_Size_Clause (Err_Ident) then
                  Err_Node := Expression (Size_Clause (Err_Ident));
               elsif Is_Type (Err_Ident)
                 and then Has_Object_Size_Clause (Err_Ident)
               then
                  Err_Node := Expression (Object_Size_Clause (Err_Ident));
               end if;

               Error_Msg_Uint_1 := UI_From_GL_Value (Pad_Sz);
               if For_Component then
                  Error_Msg_NE ("component of& padded by ^ bits?",
                                Err_Ident, Err_Ident);
               elsif Present (Err_Node) then
                  Error_Msg_NE ("^ bits of & unused?", Err_Node,
                                Err_Ident);
               end if;
            end if;
         end;
      end if;

      return Out_GT;
   end Make_GT_Alternative;

   ----------------------------------
   -- Make_GT_Alternative_Internal --
   ----------------------------------

   function Make_GT_Alternative_Internal
     (GT        : GL_Type;
      Size      : Uint;
      Align     : Uint;
      For_Type  : Boolean;
      Max_Size  : Boolean;
      Is_Biased : Boolean) return GL_Type
   is
      In_GTI      : constant GL_Type_Info := GL_Type_Table.Table (GT);
      Needs_Bias  : constant Boolean      :=
        Is_Biased or else In_GTI.Kind = Biased;
      Needs_Max   : constant Boolean      := Max_Size or else In_GTI.Max_Size;
      Max_Int_Sz  : constant Uint         := UI_From_Int (64);
      TE          : constant Entity_Id    := Full_Etype (GT);
      Prim_GT     : constant GL_Type      := Primitive_GL_Type (GT);
      Prim_Native : constant Boolean      := not Is_Nonnative_Type (Prim_GT);
      Prim_T      : constant Type_T       := Type_Of (Prim_GT);
      Prim_Fixed  : constant Boolean      := not Is_Dynamic_Size (Prim_GT);
      Prim_Size   : constant GL_Value     :=
        (if Prim_Fixed then Get_Type_Size (Prim_GT) else No_GL_Value);
      Prim_Align  : constant GL_Value     := Get_Type_Alignment (Prim_GT);
      Int_Sz      : constant Uint         :=
        (if Size = 0 then Uint_1 else Size);
      Size_Bytes  : constant Uint         :=
        (if   Size = No_Uint or else Is_Dynamic_SO_Ref (Size) then No_Uint
         else (Size + BPU - 1) / BPU);
      Size_V      : GL_Value              :=
        (if   Size_Bytes = No_Uint or else not UI_Is_In_Int_Range (Size_Bytes)
         then In_GTI.Size else Size_Const_Int (Size_Bytes));
      Align_V     : constant GL_Value     :=
        (if   Align = No_Uint or else Is_Dynamic_SO_Ref (Align)
         then In_GTI.Alignment else Size_Const_Int (Align));
      Found_GT    : GL_Type               := Get_GL_Type (TE);

   begin
      --  If we're not specifying a size, alignment, or a request for
      --  maximum size, we want the original type.  This isn't quite the
      --  same test as below since it will get confused with 0-sized types.

      if No (Size_V) and then No (Align_V) and then not Needs_Max then
         return GT;

      --  If the best type we had is a dummy type, don't make any alternatives

      elsif Is_Dummy_Type (Prim_GT) then
         return Prim_GT;

      --  If we're asking for the maximum size, the maximum size is a
      --  constant, and we don't have a specified size, use the maximum size.

      elsif Needs_Max and then not Is_Dynamic_Size (Prim_GT, Max_Size => True)
        and then No (Size_V)
      then
         Size_V := Get_Type_Size (Prim_GT, Max_Size => True);
      end if;

      --  If this is for a type, we haven't specified a size, we have to
      --  align the input size.

      if For_Type and then Size = No_Uint and then Present (Size_V)
        and then Present (Align_V) and then U_Rem (Size_V, Align_V) /= 0
      then
         Size_V := Align_To (Size_V, 1, Get_Const_Int_Value_ULL (Align_V));
      end if;

      --  See if we already made a matching GL_Type

      while Present (Found_GT) loop
         declare
            GTI : constant GL_Type_Info := GL_Type_Table.Table (Found_GT);
         begin
            if (Size_V = GTI.Size and then Align_V = GTI.Alignment
                  and then Needs_Bias = (GTI.Kind = Biased)
                  and then not (Needs_Max
                                  and then (No (Size_V)
                                              or else not Prim_Native))
                  and then not (Size /= No_Uint
                                  and then (Get_Type_Kind (GTI.LLVM_Type) =
                                              Integer_Type_Kind)
                                  and then (Get_Type_Size_In_Bits
                                              (GTI.LLVM_Type) /=
                                              UI_To_ULL (Size))))
              --  If the size and alignment are the same, this must be the
              --  same type.  But this isn't the case if we need the
              --  maximim size and there's no size for the type or the
              --  primitive type isn't native (the latter can happen for a
              --  variant record where all the variants are the same size.)
              --  Also check for the integral case when the size isn't the
              --  number of bits.

              or else (Needs_Max and then GTI.Max_Size)
              --  It's also the same type even if there's no match if
              --  we want the maximum size and we have an entry where
              --  we got the maximum size.

              or else (not Is_Discrete_Or_Fixed_Point_Type (GT)
                         and then GTI.Kind = Primitive
                         and then Present (Size_V) and then Present (GTI.Size)
                         and then Size_V < GTI.Size)
              --  ??? Until we support field rep clauses, don't try to make
              --  non-integer types smaller.

            then
               return Found_GT;
            end if;
         end;

         Next (Found_GT);
      end loop;

      --  Otherwise, we have to create a new GL_Type.  We know that the
      --  size, alignment, or both differ from that of the primitive type.

      declare
         Ret_GT : constant GL_Type := New_GT (TE);
         GTI    : GL_Type_Info renames GL_Type_Table.Table (Ret_GT);

      begin
         --  Record the basic parameters of what we're making

         GTI.Size      := Size_V;
         GTI.Alignment := Align_V;
         GTI.Max_Size  := Needs_Max;

         --  If this is a biased type, make a narrower integer and set the
         --  bias.

         if Needs_Bias then
            declare
               LB, HB : GL_Value;

            begin
               Bounds_From_Type (Prim_GT, LB, HB);
               GTI.LLVM_Type :=
                 (if Int_Sz = No_Uint then Prim_T else Int_Ty (Int_Sz));
               GTI.Kind      := Biased;
               GTI.Bias      := LB;
            end;

         --  If this is a discrete or fixed-point type and a size was
         --  specified that's no larger than the largest integral type,
         --  make an alternate integer type.

         elsif Is_Discrete_Or_Fixed_Point_Type (GT)
           and then Size /= No_Uint and then Size <= Max_Int_Sz
         then
            GTI.LLVM_Type := Int_Ty (Int_Sz);
            GTI.Kind      := Int_Alt;

         --  If we have a native primitive type, we specified a size, and
         --  the size or alignment is different that that of the primitive,
         --  we make a padded type.

         elsif Prim_Native and then Present (Size_V)
           and then (Prim_Size /= Size_V
                       or else (Present (Align_V)
                                  and then Prim_Align /= Align_V))
         then
            declare
               Pad_Size  : constant GL_Value := Size_V - Prim_Size;
               Pad_Count : constant LLI      := Get_Const_Int_Value (Pad_Size);
               Arr_T     : constant Type_T   :=
                 Array_Type (Byte_T, unsigned (Pad_Count));

            begin
               --  If there's a padding amount, thisis a padded type.
               --  Otherwise, this is an aligning type.

               if Pad_Count > 0 then
                  GTI.LLVM_Type := Build_Struct_Type ((1 => Prim_T,
                                                       2 => Arr_T),
                                                      Packed => True);
                  GTI.Kind      := Padded;
               else
                  GTI.LLVM_Type := Prim_T;
                  GTI.Kind      := Aligning;
               end if;
            end;

         --  If we're making a fixed-size version of something of dynamic
         --  size (possibly because we need the maximim size), we need a
         --  Byte_Array.

         elsif not Prim_Native and then Present (Size_V) then
            GTI.LLVM_Type := Array_Type (Byte_T, unsigned (Get_Const_Int_Value
                                                             (Size_V)));
            GTI.Kind      := Byte_Array;

         --  If we're looking for the maximum size and none of the above cases
         --  are true, we just make a GT showing that's what we need.

         elsif Needs_Max then
            GTI.LLVM_Type := Prim_T;
            GTI.Kind      := Max_Size_Type;

         --  Othewise, we must just be changing the alignment of a
         --  variable-size type.

         else
            GTI.LLVM_Type := Prim_T;
            GTI.Kind      := Aligning;
         end if;

         if For_Type then
            Mark_Default (Ret_GT);
         end if;

         return Ret_GT;
      end;
   end Make_GT_Alternative_Internal;

   --------------------
   -- Update_GL_Type --
   --------------------

   procedure Update_GL_Type (GT : GL_Type; T : Type_T; Is_Dummy : Boolean) is
      GTI : GL_Type_Info renames GL_Type_Table.Table (GT);

   begin
      GTI.LLVM_Type := T;
      GTI.Kind      := (if Is_Dummy then Dummy else Primitive);
      Mark_Default (GT);

      --  If Size_Type hasn't been elaborated yet, we're done for now.
      --  If this is a E_Void or E_Subprogram_Type, it doesn't have a
      --  size or alignment.  Otherwise, set the alignment and also
      --  set the size if it's a constant.

      if Present (Size_GL_Type) and then not Is_Dummy
        and then Ekind (GT) not in E_Void | E_Subprogram_Type
      then
         GTI.Alignment := Get_Type_Alignment (GT);
         if not Is_Dynamic_Size (GT) then
            GTI.Size   := Get_Type_Size (GT);
         end if;
      end if;

   end Update_GL_Type;

   -----------------------
   -- Primitive_GL_Type --
   -----------------------

   function Primitive_GL_Type (TE : Entity_Id) return GL_Type is
      GT : GL_Type := Get_Or_Create_GL_Type (TE, True);

   begin
      --  First look for a primitive type.  If there isn't one, then a
      --  dummy type is the best we have.

      while Present (GT) loop
         exit when GL_Type_Table.Table (GT).Kind = Primitive;
         Next (GT);
      end loop;

      if No (GT) then
         GT := Get_GL_Type (TE);
         while Present (GT) loop
            exit when GL_Type_Table.Table (GT).Kind = Dummy;
            Next (GT);
         end loop;
      end if;

      --  If what we got was a dummy type, try again to make a type.  Note that
      --  we may not have succeded, so we may get the dummy type back.

      if Present (GT) and then Is_Dummy_Type (GT) then
         Discard (Type_Of (TE));
         GT := Get_GL_Type (TE);

         while Present (GT) loop
            exit when GL_Type_Table.Table (GT).Kind = Primitive;
            Next (GT);
         end loop;

         if No (GT) then
            GT := Get_GL_Type (TE);
            while Present (GT) loop
               exit when GL_Type_Table.Table (GT).Kind = Dummy;
               Next (GT);
            end loop;
         end if;
      end if;

      return GT;
   end Primitive_GL_Type;

   -----------------------
   -- Primitive_GL_Type --
   -----------------------

   function Primitive_GL_Type (GT : GL_Type) return GL_Type is
     (Primitive_GL_Type (Full_Etype (GT)));

   -----------------------
   -- Primitive_GL_Type --
   -----------------------

   function Primitive_GL_Type (V : GL_Value) return GL_Type is
     (Primitive_GL_Type (Full_Etype (Related_Type (V))));

   -------------------
   -- Dummy_GL_Type --
   -------------------

   function Dummy_GL_Type (TE : Entity_Id) return GL_Type is
   begin
      return GT : GL_Type := Get_Or_Create_GL_Type (TE, False) do
         while Present (GT) loop
            exit when GL_Type_Table.Table (GT).Kind = Dummy;
            Next (GT);
         end loop;
      end return;
   end Dummy_GL_Type;

   ---------------------
   -- Default_GL_Type --
   ---------------------

   function Default_GL_Type
     (TE : Entity_Id; Create : Boolean := True) return GL_Type is
   begin
      return GT : GL_Type := Get_Or_Create_GL_Type (TE, Create) do
         while Present (GT) loop
            exit when GL_Type_Table.Table (GT).Default;
            Next (GT);
         end loop;

         --  If what we got was a dummy type, try again to make a type.
         --  Note that we may not have succeded, so we may get the dummy
         --  type back.

         if Create and then Present (GT) and then Is_Dummy_Type (GT) then
            Discard (Type_Of (TE));
            GT := Get_GL_Type (TE);

            while Present (GT) loop
               exit when GL_Type_Table.Table (GT).Default;
               Next (GT);
            end loop;
         end if;
      end return;
   end Default_GL_Type;

   ------------------
   -- Mark_Default --
   ------------------

   procedure Mark_Default (GT : GL_Type) is
      All_GT : GL_Type := Get_GL_Type (Full_Etype (GT));

   begin
      --  Mark each GT as default or not, depending on whether it's ours

      while Present (All_GT) loop
         GL_Type_Table.Table (All_GT).Default := All_GT = GT;
         Next (All_GT);
      end loop;
   end Mark_Default;

   -----------------
   -- Convert_Int --
   -----------------

   function Convert_Int (V : GL_Value; GT : GL_Type) return GL_Value is
      type Cvtf is access function
        (V : GL_Value; GT : GL_Type; Name : String := "") return GL_Value;

      T           : constant Type_T  := Type_Of (GT);
      In_GT       : constant GL_Type := Related_Type (V);
      Src_Uns     : constant Boolean := Is_Unsigned_For_Convert (In_GT);
      Src_Size    : constant Nat     := Nat (ULL'(Get_Type_Size_In_Bits (V)));
      Dest_Size   : constant Nat     := Nat (ULL'(Get_Type_Size_In_Bits (T)));
      Is_Trunc    : constant Boolean := Dest_Size < Src_Size;
      Subp        : Cvtf             := null;

   begin
      --  If the value is already of the desired LLVM type, we're done.

      if Type_Of (V) = Type_Of (GT) then
         return G_Is (V, GT);
      elsif Is_Trunc then
         Subp := Trunc'Access;
      else
         Subp := (if Src_Uns then Z_Ext'Access else S_Ext'Access);
      end if;

      return Subp (V, GT);
   end Convert_Int;

   ------------------
   -- To_Primitive --
   ------------------

   function To_Primitive   (V : GL_Value) return GL_Value is
      In_GT  : constant GL_Type      := Related_Type (V);
      In_GTI : constant GL_Type_Info := GL_Type_Table.Table (In_GT);
      Out_GT : constant GL_Type      := Primitive_GL_Type (Full_Etype (In_GT));
      Is_Ref : constant Boolean      := Is_Reference (V);
      Result : GL_Value              := V;

   begin
      --  If this is a double reference, convert it to a single reference

      if Is_Double_Reference (Result) then
         Result := Load (Result);
      end if;

      --  If we're already primitive, done

      if Is_Primitive_GL_Type (In_GT) then
         return Result;

      --  Unless this is Biased or Padded, if this is a reference,
      --  just convert the pointer.  But if it's a reference to bounds and
      --  data, always do it this way.

      elsif Relationship (V) = Reference_To_Bounds_And_Data
        or else (In_GTI.Kind not in Biased | Padded and Is_Ref)
      then
         return Ptr_To_Relationship (Result, Out_GT, Relationship (Result));

      --  If this is Aligning or Max_Size, the object is the same, we
      --  just note that it now has the right type.

      elsif In_GTI.Kind in Aligning | Max_Size_Type then
         return G_Is (Result, Out_GT);

      --  For Biased, we need to be sure we have data, then convert to
      --  the underlying type, then add the bias.

      elsif In_GTI.Kind = Biased then
         return Convert_Int (Get (Result, Data), Out_GT) + In_GTI.Bias;

      --  For Dummy, this must be an access type, so just convert to the
      --  proper pointer.

      elsif In_GTI.Kind = Dummy then
         return Convert_Pointer (Result, Out_GT);

      --  For Int_Alt, this must be an integral type, so convert it to
      --  the desired alternative.

      elsif In_GTI.Kind = Int_Alt then
         return Convert_Int (Result, Out_GT);

      --  For Padded, use either GEP or Extract_Value, depending on whether
      --  this is a reference or not.

      elsif In_GTI.Kind = Padded then
         return (if   Is_Ref
                 then GEP (Out_GT, Result,
                           (1 => Const_Null_32, 2 => Const_Null_32))
                 else Extract_Value (Out_GT, Result, 0));

      --  The remaining case must be a byte array where we have data, not
      --  a reference.  In this case, we have to store the data into memory
      --  and convert the memory pointer to the proper type.

      else
         pragma Assert (In_GTI.Kind = Byte_Array and not Is_Ref);
         Result := Get (Result, Any_Reference);
         return Ptr_To_Relationship (Result, Out_GT, Relationship (Result));
      end if;

   end To_Primitive;

   --------------------
   -- From_Primitive --
   --------------------

   function From_Primitive (V : GL_Value; GT : GL_Type) return GL_Value is
      GTI    : constant GL_Type_Info := GL_Type_Table.Table (GT);
      Is_Ref : constant Boolean      := Is_Reference (V);
      Result : GL_Value              := V;

   begin
      --  If this is a double reference, convert it to a single reference

      if Is_Double_Reference (Result) then
         Result := Load (Result);
      end if;

      --  If we're already the requested type, done

      if Related_Type (V) = GT then
         return Result;

      --  Unless the result is Biased, if this is a reference, just
      --  convert the pointer.

      elsif GTI.Kind /= Biased and Is_Ref then
         return Ptr_To_Relationship (Result, GT, Relationship (Result));

      --  If the result is Aligning or Max_Size, the object is the
      --  same, we just note that it now has the right type.

      elsif GTI.Kind in Aligning | Max_Size_Type then
         return G_Is (Result, GT);

      --  For Biased, we need to be sure we have data, then subtract
      --  the bias, then convert to the underlying type.

      elsif GTI.Kind = Biased then
         return Trunc (Get (Result, Data) - GTI.Bias, GT);

      --  For Dummy, this must be an access type, so just convert to the
      --  proper pointer.

      elsif GTI.Kind = Dummy then
         return Convert_Pointer (Result, GT);

      --  For Int_Alt, this must be an integral type, so convert it to
      --  the desired alternative.

      elsif GTI.Kind = Int_Alt then
         return Convert_Int (Result, GT);

      --  For Padded, we know this is data, so use Insert_Value to
      --  make the padded version.

      elsif GTI.Kind = Padded then
         return Insert_Value (Get_Undef (GT), V, 0);

      --  The remaining case must be a byte array where we have data, not
      --  a reference.  In this case, we have to store the data into memory
      --  and convert the memory pointer to the proper type.

      else
         pragma Assert (GTI.Kind = Byte_Array and not Is_Ref);
         Result := Get (Result, Any_Reference);
         return Ptr_To_Relationship (Result, GT, Relationship (Result));
      end if;

   end From_Primitive;

   ----------------
   -- Full_Etype --
   ----------------

   function Full_Etype (GT : GL_Type) return Entity_Id is
     (GL_Type_Table.Table (GT).GNAT_Type);

   -------------
   -- Type_Of --
   -------------

   function Type_Of (GT : GL_Type) return Type_T is
     (GL_Type_Table.Table (GT).LLVM_Type);

   ------------------
   -- Base_GL_Type --
   -----------------

   function Base_GL_Type (TE : Entity_Id) return GL_Type is
     (Primitive_GL_Type (Full_Base_Type (TE)));

   ------------------
   -- Base_GL_Type --
   -----------------

   function Base_GL_Type (GT : GL_Type) return GL_Type is
     (Primitive_GL_Type (Full_Base_Type (GT)));

   ------------------------
   -- Full_Alloc_GL_Type --
   ------------------------

   function Full_Alloc_GL_Type (N : Node_Id) return GL_Type is
      TE : Entity_Id := Full_Etype (N);

   begin
      if Is_Entity_Name (N)
        and then (Ekind_In (Entity (N), E_Constant, E_Variable)
                    or else Is_Formal (Entity (N)))
        and then Present (Actual_Subtype (Entity (N)))
      then
         TE := Get_Fullest_View (Actual_Subtype (Entity (N)));
      end if;

      return Default_GL_Type (TE);
   end Full_Alloc_GL_Type;

   --------------------
   --  Is_Dummy_Type --
   --------------------

   function Is_Dummy_Type (GT : GL_Type) return Boolean is
     (GL_Type_Table.Table (GT).Kind = Dummy);

   ---------------------------
   --  Is_Primitive_GL_Type --
   ---------------------------

   function Is_Primitive_GL_Type (GT : GL_Type) return Boolean is
     (GL_Type_Table.Table (GT).Kind = Primitive);

   ------------------------
   --  Is_Biased_GL_Type --
   ------------------------

   function Is_Biased_GL_Type (GT : GL_Type) return Boolean is
     (GL_Type_Table.Table (GT).Kind = Biased);

   ------------------------
   --  Is_Padded_GL_Type --
   ------------------------

   function Is_Padded_GL_Type (GT : GL_Type) return Boolean is
     (GL_Type_Table.Table (GT).Kind = Padded);

   ---------------------------
   --  Is_Bye_Array_GL_Type --
   ---------------------------

   function Is_Byte_Array_GL_Type (GT : GL_Type) return Boolean is
     (GL_Type_Table.Table (GT).Kind = Byte_Array);

   ----------------------
   -- Is_Empty_GL_Type --
   ----------------------

   function Is_Empty_GL_Type (GT : GL_Type) return Boolean is
     (GL_Type_Table.Table (GT).Kind = None);

   -----------------------
   -- Is_Nonnative_Type --
   -----------------------

   function Is_Nonnative_Type (GT : GL_Type) return Boolean is
      GTI  : constant GL_Type_Info := GL_Type_Table.Table (GT);

   begin
      --  If we've built an LLVM type to do padding, then that's a native
      --  type.  Otherwise, we have to look at whether the underlying type
      --  has a native representation or not.

      return GTI.Kind not in Padded | Byte_Array
        and then Is_Nonnative_Type (GTI.GNAT_Type);
   end Is_Nonnative_Type;

   -----------------------------
   -- Full_Designated_GL_Type --
   -----------------------------

   function Full_Designated_GL_Type (GT : GL_Type) return GL_Type is
      TE : constant Entity_Id := Full_Etype (GT);
      DT : constant GL_Type   := Get_Associated_GL_Type (TE);

   begin
      --  Normally, we've saved the associated GL_Type.  But we don't do
      --  this in the E_Subprogram_Type case.

      return (if   Present (DT) then DT
              else Default_GL_Type (Full_Designated_Type (TE)));

   end Full_Designated_GL_Type;

   -----------------------------
   -- Full_Designated_GL_Type --
   -----------------------------

   function Full_Designated_GL_Type (V : GL_Value) return GL_Type is
      TE : constant Entity_Id := Full_Etype (Related_Type (V));

   begin
      --  If this isn't an actual access type, but a reference to
      --  something, the type is that thing.

      if Is_Reference (V) then
         return Related_Type (V);

      --  Otherwise, return the associated type, if there is one, of the
      --  designated type.

      elsif Present (Get_Associated_GL_Type (TE)) then
         return Get_Associated_GL_Type (TE);

      --  Otherwise, get the default_GL_Type of what it points to (the --
      --  E_Subprogram_Type case).

      else
         return Default_GL_Type (Full_Designated_Type (TE));
      end if;

   end Full_Designated_GL_Type;

   ----------------------
   -- Dump_GL_Type_Int --
   ----------------------

   procedure Dump_GL_Type_Int (GT : GL_Type; Full_Dump : Boolean) is
      GTI  : constant GL_Type_Info := GL_Type_Table.Table (GT);

   begin
      Write_Str (GT_Kind'Image (GTI.Kind) & "(");
      Write_Int (Int (GTI.GNAT_Type));
      if Present (GTI.Size) then
         Write_Str (", S=");
         Write_Int (Int (Get_Const_Int_Value (GTI.Size)));
      end if;
      if Present (GTI.Alignment) then
         Write_Str (", A=");
         Write_Int (Int (Get_Const_Int_Value (GTI.Alignment)));
      end if;
      if Present (GTI.Bias) then
         Write_Str (", B=");
         Write_Int (Int (Get_Const_Int_Value (GTI.Bias)));
      end if;

      Write_Str (")");
      if Full_Dump then
         Write_Str (": ");
         if Present (GTI.LLVM_Type) then
            Dump_LLVM_Type (GTI.LLVM_Type);
         end if;

         pg (Union_Id (GTI.GNAT_Type));
      end if;
   end Dump_GL_Type_Int;

begin
   --  Make a dummy entry in the table, so the "No" entry is never used.

   GL_Type_Table.Increment_Last;
end GNATLLVM.GLType;
