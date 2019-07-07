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

with Snames;   use Snames;

with LLVM.Core;  use LLVM.Core;

with GNATLLVM.Arrays.Create; use GNATLLVM.Arrays.Create;
with GNATLLVM.Compile;       use GNATLLVM.Compile;
with GNATLLVM.Conversions;   use GNATLLVM.Conversions;
with GNATLLVM.DebugInfo;     use GNATLLVM.DebugInfo;
with GNATLLVM.Exprs;         use GNATLLVM.Exprs;
with GNATLLVM.Records;       use GNATLLVM.Records;
with GNATLLVM.Subprograms;   use GNATLLVM.Subprograms;
with GNATLLVM.Variables;     use GNATLLVM.Variables;

package body GNATLLVM.Arrays is

   function Type_For_Get_Bound (GT : GL_Type; V : GL_Value) return GL_Type
     with Pre  => Is_Array_Or_Packed_Array_Type (GT),
          Post => Is_Array_Or_Packed_Array_Type (Type_For_Get_Bound'Result);
   --  Get the best type to use to search for a bound of an arrray

   function Emit_Expr_For_Minmax
     (N : Node_Id; Is_Low : Boolean) return GL_Value
     with Pre => Present (N);
   --  Compute the value of N viewing any discriminant encountered as
   --  being either their lowest or highest values, respectively

   function Bound_Complexity (B : One_Bound; Max_Size : Boolean) return Nat is
      (if    B.Cnst /= No_Uint then 0 elsif Present (B.Value) then 1
       elsif Max_Size then 1 else 2);

   function Get_GEP_Safe_Type (V : GL_Value) return GL_Type
     with Pre  => Is_Data (V),
          Post => Is_Integer_Type (Get_GEP_Safe_Type'Result);
   --  GEP treats array indices as signed values.  If the type is unsigned
   --  (including Boolean; see C55C02B), it will sign-extend rather than
   --  zero-extend the value.  So if this type is smaller than the size of
   --  a pointer and is unsigned, we must return a wider type.

   function Emit_Constant_Aggregate
     (N : Node_Id; Comp_Type, GT : GL_Type; Dims_Left : Nat) return GL_Value
     with Pre  => Nkind_In (N, N_Aggregate, N_Extension_Aggregate)
                  and then Is_Array_Type (GT) and then Present (Comp_Type),
          Post => Is_Constant (Emit_Constant_Aggregate'Result);
   --  N is a constant aggregate.  GT is either the array type (at the
   --  outer level) or Any_Array (if not).  Comp_Type is the underlying
   --  component type of the array, and Dims_Left are the number of dimensions
   --  remaining.  Return an LLVM constant including all of the constants
   --  in that aggregate.

   function Swap_Indices
     (Idxs : GL_Value_Array; V : GL_Value) return GL_Value_Array
     with Pre  => Is_Array_Type (Related_Type (V)),
          Post => Swap_Indices'Result'Length = Idxs'Length;
   --  Given a list of indices, swap them if V is a Fortran array

   --  We put the routines used to compute sizes into a generic so that we
   --  can instantiate them using various types of sizing.  The most common
   --  case is an actual size computation, where we produce a GL_Value.
   --  But we may also instantiate this package to generate the structure
   --  needed for back-annotation.

   generic
      type Result is private;
      Empty_Result : Result;
      with function Sz_Const
        (C : ULL; Sign_Extend : Boolean := False) return Result;
      with function Sz_Const_Int (GT : GL_Type; C : Uint) return Result;
      with function Sz_Type_Size
        (GT          : GL_Type;
         V           : GL_Value := No_GL_Value;
         Max_Size    : Boolean  := False;
         No_Paddding : Boolean  := False) return Result;
      with function  Sz_I_Cmp
        (Op : Int_Predicate_T;
         LHS : Result;
         RHS : Result;
         Name : String := "") return Result;
      with function  "+" (V1, V2 : Result) return Result;
      with function  "-" (V1, V2 : Result) return Result;
      with function  "*" (V1, V2 : Result) return Result;
      with function  "/" (V1, V2 : Result) return Result;
      with function  Sz_Neg (V : Result; Name : String := "") return Result;
      with function  Sz_S_Div
        (V1, V2 : Result; Name : String := "") return Result;
      with function  Sz_Select
        (C_If, C_Then, C_Else : Result; Name : String := "") return Result;
      with function  Sz_Min
        (V1, V2 : Result; Name : String := "") return Result;
      with function  Sz_Max
        (V1, V2 : Result; Name : String := "") return Result;
      with function  Sz_Extract_Value
        (GT      : GL_Type;
         V       : GL_Value;
         Idx_Arr : Index_Array;
         Name    : String := "") return Result;
      with function  Sz_Convert
        (V              : Result;
         GT             : GL_Type;
         Float_Truncate : Boolean := False;
         Is_Unsigned    : Boolean := False) return Result;
      with function  Sz_Emit_Expr
        (V : Node_Id; LHS : Result := Empty_Result) return Result;
      with function  Sz_Emit_Convert
        (N : Node_Id; GT : GL_Type) return Result;
      with function  Sz_Undef     (GT : GL_Type) return Result;
      with function  Sz_Is_Const  (V : Result) return Boolean;
      with function  Sz_Const_Val (V : Result) return ULL;
   package Size is

      function No      (V : Result) return Boolean is (V = Empty_Result);
      function Present (V : Result) return Boolean is (V /= Empty_Result);

      function Bounds_To_Length
        (In_Low, In_High : Result;
         GT              : GL_Type;
         Not_Superflat   : Boolean := False) return Result;

      function Emit_Expr_For_Minmax
        (N : Node_Id; Is_Low : Boolean) return Result;

      function Get_Array_Bound
        (GT       : GL_Type;
         Dim      : Nat;
         Is_Low   : Boolean;
         V        : GL_Value;
         Max_Size : Boolean := False;
         For_Orig : Boolean := False) return Result;

      function Get_Array_Length
        (TE       : Entity_Id;
         Dim      : Nat;
         V        : GL_Value;
         Max_Size : Boolean := False) return Result;

      function Get_Array_Elements
        (V        : GL_Value;
         TE       : Entity_Id;
         Max_Size : Boolean := False) return Result;

      function Get_Array_Type_Size
        (TE       : Entity_Id;
         V        : GL_Value;
         Max_Size : Boolean := False) return Result;

   end Size;

   ------------------------
   -- Type_For_Get_Bound --
   ------------------------

   function Type_For_Get_Bound
     (GT : GL_Type; V : GL_Value) return GL_Type
   is
      V_GT : constant GL_Type :=
        (if No (V) then No_GL_Type else Related_Type (V));

   begin
      --  If only GT is around, use it.  Likewise if V_Type is not an array
      --  type or not related to GT.  Otherwise, use the type that's
      --  constrained, preferring V's type, but only if GT is
      --  unconstrained.

      if No (V_GT) or else not Is_Array_Type (V_GT)
        or else (Ultimate_Base_Type (V_GT) /= Ultimate_Base_Type (GT))
        or else not Is_Unconstrained_Array (GT)
        or else (not Is_Constrained (V_GT) and then Is_Constrained (GT))
      then
         return GT;
      else
         return V_GT;
      end if;

   end Type_For_Get_Bound;

   package body Size is

      ----------------------
      -- Bounds_To_Length --
      ----------------------

      function Bounds_To_Length
        (In_Low, In_High : Result;
         GT              : GL_Type;
         Not_Superflat   : Boolean := False) return Result
      is
         Low      : constant Result          := Sz_Convert (In_Low, GT);
         High     : constant Result          := Sz_Convert (In_High, GT);
         Const_0  : constant Result          := Sz_Const_Int (GT, Uint_0);
         Const_1  : constant Result          := Sz_Const_Int (GT, Uint_1);
         Cmp_Kind : constant Int_Predicate_T :=
           (if Is_Unsigned_Type (GT) then Int_UGT else Int_SGT);

      begin
         --  If the low bound is 1, then this is either the max of zero and the
         --  high bound or the high bound if this is known not to be superflat.

         if Low = Const_1 then
            return (if Not_Superflat then High else Sz_Max (High, Const_0));

         --  Otherwise, it's zero if this is flat or superflat and High -
         --  Low + 1 otherwise.

         elsif Not_Superflat then
            return High - Low + Const_1;

         else
            return Sz_Select
              (C_If   => Sz_I_Cmp (Cmp_Kind, Low, High, "is-empty"),
               C_Then => Const_0,
               C_Else => High - Low + Const_1);
         end if;

      end Bounds_To_Length;

      --------------------------
      -- Emit_Expr_For_Minmax --
      --------------------------

      function Emit_Expr_For_Minmax
        (N : Node_Id; Is_Low : Boolean) return Result
      is
         Attr     : Attribute_Id;
         RHS, LHS : Result;

      begin
         --  If N doesn't involve a discriminant, just evaluate it

         if not Contains_Discriminant (N) then
            return Sz_Emit_Expr (N);
         end if;

         case Nkind (N) is
            when N_Identifier =>

               --  If we get here, this must be a discriminant

               pragma Assert (Ekind (Entity (N)) = E_Discriminant);
               declare
                  GT    : constant GL_Type := Full_GL_Type (Entity (N));
                  Limit : constant Node_Id :=
                    (if   Is_Low then Type_Low_Bound (GT)
                     else Type_High_Bound (GT));

               begin
                  return Sz_Emit_Expr (Limit);
               end;

            when N_Attribute_Reference =>

               --  The only ones we support are 'Range_Length, 'Min, and 'Max

               Attr := Get_Attribute_Id (Attribute_Name (N));
               if Attr = Attribute_Range_Length
                 and then Is_Scalar_Type (Full_Etype (Prefix (N)))
               then
                  declare
                     PT : constant GL_Type := Full_GL_Type (Prefix (N));
                     LB : constant Node_Id := Type_Low_Bound  (PT);
                     HB : constant Node_Id := Type_High_Bound (PT);

                  begin
                     LHS := Emit_Expr_For_Minmax (LB, True);
                     RHS := Emit_Expr_For_Minmax (HB, False);
                     return Bounds_To_Length (LHS, RHS, Full_GL_Type (N));
                  end;
               else
                  pragma Assert (Attr in Attribute_Min | Attribute_Max);
                  LHS :=
                    Emit_Expr_For_Minmax (First (Expressions (N)), Is_Low);
                  RHS :=
                    Emit_Expr_For_Minmax (Last  (Expressions (N)), Is_Low);
                  return (if   Attr = Attribute_Min then Sz_Min (LHS, RHS)
                          else Sz_Max (LHS, RHS));
               end if;

            when N_Op_Minus =>
               LHS := Emit_Expr_For_Minmax (Right_Opnd (N), not Is_Low);
               return Sz_Neg (RHS);

            when N_Op_Plus =>
               return Emit_Expr_For_Minmax (Right_Opnd (N), Is_Low);

            when N_Op_Add =>
               LHS := Emit_Expr_For_Minmax (Left_Opnd (N),  Is_Low);
               RHS := Emit_Expr_For_Minmax (Right_Opnd (N), Is_Low);
               return LHS + RHS;

            when N_Op_Subtract =>
               LHS := Emit_Expr_For_Minmax (Left_Opnd (N),  Is_Low);
               RHS := Emit_Expr_For_Minmax (Right_Opnd (N), not Is_Low);
               return LHS - RHS;

            when N_Op_Multiply =>
               LHS := Emit_Expr_For_Minmax (Left_Opnd (N),  Is_Low);
               RHS := Emit_Expr_For_Minmax (Right_Opnd (N), Is_Low);
               return LHS * RHS;

            when N_Op_Divide =>
               LHS := Emit_Expr_For_Minmax (Left_Opnd (N),  Is_Low);
               RHS := Emit_Expr_For_Minmax (Right_Opnd (N), Is_Low);
               return (if   Is_Unsigned_Type (Full_Etype (N))
                       then LHS / RHS else Sz_S_Div (LHS, RHS));

            when N_Type_Conversion | N_Unchecked_Type_Conversion =>
               LHS := Emit_Expr_For_Minmax (Expression (N), Is_Low);
               return Sz_Convert (LHS, Full_GL_Type (N));

            when N_Function_Call =>

               --  We assume here that what we have is a call to enumRP (disc)
               --  and get the 'Pos of the first or last in the range.

               declare
                  Params : constant List_Id   := Parameter_Associations (N);
                  Discr  : constant Entity_Id := Entity (First (Params));
                  GT     : constant GL_Type   := Full_GL_Type (Discr);
                  Bound  : constant Node_Id   :=
                    Entity ((if   Is_Low then Type_Low_Bound (GT)
                             else Type_High_Bound (GT)));

               begin
                  return Sz_Const_Int (Full_GL_Type (N),
                                       Enumeration_Pos (Bound));
               end;

            when others =>
               pragma Assert (False);
               return Sz_Undef (Full_GL_Type (N));
         end case;

      end Emit_Expr_For_Minmax;

      ---------------------
      -- Get_Array_Bound --
      ---------------------

      function Get_Array_Bound
        (GT       : GL_Type;
         Dim      : Nat;
         Is_Low   : Boolean;
         V        : GL_Value;
         Max_Size : Boolean := False;
         For_Orig : Boolean := False) return Result
      is
         Our_GT     : constant GL_Type       := Type_For_Get_Bound (GT, V);
         Info_Idx   : constant Array_Info_Id :=
           (if   For_Orig then Get_Orig_Array_Info (Full_Etype (Our_GT))
            else Get_Array_Info (Full_Etype (Our_GT)));
         Dim_Info   : constant Index_Bounds  :=
           Array_Info.Table (Info_Idx + Dim);
         Bound_Info : constant One_Bound     :=
           (if Is_Low then Dim_Info.Low else Dim_Info.High);
         Bound_Idx  : constant Nat := Dim  * 2 + (if Is_Low then 0 else 1);
         --  In the array fat pointer bounds structure, bounds are stored as a
         --  sequence of (lower bound, upper bound) pairs.
         Expr       : constant Node_Id       := Bound_Info.Value;
         Res        : Result;

      begin
         Push_Debug_Freeze_Pos;

         --  There are three cases: a constant size, in which case we
         --  return that size, a value, in which case we compute that
         --  value, which may involve a discriminant, and an unconstrained
         --  array, in which case we have a fat pointer and extract the
         --  bounds from it.

         if Bound_Info.Cnst /= No_Uint then
            Res := Sz_Const_Int (Dim_Info.Bound_GT, Bound_Info.Cnst);
         elsif Present (Expr) then

            --  If we're looking for the size of a type (meaning the max size)
            --  and this expression involves a discriminant, we compute the
            --  expression for its minimum or maximum value, depending on the
            --  bound, and then minimize or maximize with the bounds of the
            --  index type.

            if Max_Size and then Contains_Discriminant (Expr) then
               declare
                  Bound_GT    : constant GL_Type := Dim_Info.Bound_Sub_GT;
                  Bound_Limit : constant Node_Id :=
                    (if   Is_Low then Type_Low_Bound (Bound_GT)
                     else Type_High_Bound (Bound_GT));
                  Bound_Val   : constant Result  :=
                    Sz_Convert (Emit_Expr_For_Minmax (Bound_Limit, Is_Low),
                                Dim_Info.Bound_GT);

               begin
                  Res := Sz_Convert (Emit_Expr_For_Minmax (Expr, Is_Low),
                                     Dim_Info.Bound_GT);
                  Res := (if   Is_Low then Sz_Max (Bound_Val, Res)
                          else Sz_Min (Bound_Val, Res));
               end;
            else
               Res := Sz_Emit_Convert (Expr, Dim_Info.Bound_GT);
            end if;

         --  See if we're asking for the maximum size of an uncontrained
         --  array.  If so, return the appropriate bound.

         elsif Max_Size and then Is_Unconstrained_Array (GT) then
            declare
               Bound_GT    : constant GL_Type := Dim_Info.Bound_Sub_GT;
               Bound_Limit : constant Node_Id :=
                 (if   Is_Low then Type_Low_Bound (Bound_GT)
                  else Type_High_Bound (Bound_GT));

            begin
               Res := Sz_Convert (Sz_Emit_Expr (Bound_Limit),
                                  Dim_Info.Bound_GT);
            end;

         else
            --  We now should have the unconstrained case.  Make sure we do.
            pragma Assert (Is_Unconstrained_Array (GT)
                             and then Relationship (V) /= Reference);

            Res := Sz_Extract_Value
              (Dim_Info.Bound_GT, Get (V, Bounds),
               (1 => unsigned (Bound_Idx)),
               (if Is_Low then "low-bound" else "high-bound"));
         end if;

         Pop_Debug_Freeze_Pos;
         return Res;
      end Get_Array_Bound;

      ----------------------
      -- Get_Array_Length --
      ----------------------

      function Get_Array_Length
        (TE       : Entity_Id;
         Dim      : Nat;
         V        : GL_Value;
         Max_Size : Boolean := False) return Result
      is
         Low_Bound  : constant Result :=
           Get_Array_Bound (Default_GL_Type (TE), Dim, True,  V, Max_Size);
         High_Bound : constant Result :=
           Get_Array_Bound (Default_GL_Type (TE), Dim, False, V, Max_Size);

      begin
         --  The length of an array that has the maximum range of its type
         --  is not representable in that type (it's one too high).  Rather
         --  than trying to find some suitable type, we use Size_Type,
         --  which will also make thing simpler for some of our callers.

         return Bounds_To_Length (Low_Bound, High_Bound, Size_GL_Type,
                                  Array_Not_Superflat (TE, Dim));
      end Get_Array_Length;

      ------------------------
      -- Get_Array_Elements --
      ------------------------

      function Get_Array_Elements
        (V        : GL_Value;
         TE       : Entity_Id;
         Max_Size : Boolean := False) return Result is
      begin
         return Size : Result := Sz_Const (1) do

            --  Go through every array dimension.  Get its size and
            --  multiply all of them together.

            for Dim in Nat range 0 .. Number_Dimensions (TE) - 1 loop
               Size := Size * Get_Array_Length (TE, Dim, V, Max_Size);
            end loop;
         end return;
      end Get_Array_Elements;

      -------------------------
      -- Get_Array_Type_Size --
      -------------------------

      function Get_Array_Type_Size
        (TE       : Entity_Id;
         V        : GL_Value;
         Max_Size : Boolean := False) return Result
      is
         Comp_GT      : constant GL_Type := Full_Component_GL_Type (TE);
         Comp_Size    : constant Result  :=
           Sz_Type_Size (Comp_GT, Max_Size => True);
         Num_Elements : constant Result  :=
           Get_Array_Elements (V, TE, Max_Size);

      begin
         return Sz_Convert (Comp_Size, Size_GL_Type) *
           Sz_Convert (Num_Elements, Size_GL_Type);
      end Get_Array_Type_Size;

   end Size;

   --  Here we instantiate the size routines with functions that compute
   --  the LLVM value of size and make those visible to clients.

   package LLVM_Size is
      new Size (Result           => GL_Value,
                Empty_Result     => No_GL_Value,
                Sz_Const         => Size_Const_Int,
                Sz_Const_Int     => Const_Int,
                Sz_Type_Size     => Get_Type_Size,
                Sz_I_Cmp         => I_Cmp,
                "+"              => "+",
                "-"              => "-",
                "*"              => "*",
                "/"              => "/",
                Sz_Neg           => Neg,
                Sz_S_Div         => S_Div,
                Sz_Select        => Build_Select,
                Sz_Min           => Build_Min,
                Sz_Max           => Build_Max,
                Sz_Extract_Value => Extract_Value,
                Sz_Convert       => Convert,
                Sz_Emit_Expr     => Emit_Safe_Expr,
                Sz_Emit_Convert  => Emit_Convert_Value,
                Sz_Is_Const      => Is_A_Const_Int,
                Sz_Const_Val     => Get_Const_Int_Value_ULL,
                Sz_Undef         => Get_Undef);

   function Bounds_To_Length
     (In_Low, In_High : GL_Value;
      GT              : GL_Type;
      Not_Superflat   : Boolean := False) return GL_Value
     renames LLVM_Size.Bounds_To_Length;

   function Emit_Expr_For_Minmax
     (N : Node_Id; Is_Low : Boolean) return GL_Value
     renames LLVM_Size.Emit_Expr_For_Minmax;

   function Get_Array_Bound
     (GT       : GL_Type;
      Dim      : Nat;
      Is_Low   : Boolean;
      V        : GL_Value;
      Max_Size : Boolean := False;
      For_Orig : Boolean := False) return GL_Value
     renames LLVM_Size.Get_Array_Bound;

   function Get_Array_Length
     (TE       : Entity_Id;
      Dim      : Nat;
      V        : GL_Value;
      Max_Size : Boolean := False) return GL_Value
     renames LLVM_Size.Get_Array_Length;

   function Get_Array_Elements
     (V        : GL_Value;
      TE       : Entity_Id;
      Max_Size : Boolean := False) return GL_Value
     renames LLVM_Size.Get_Array_Elements;

   function Get_Array_Type_Size
     (TE       : Entity_Id;
      V        : GL_Value;
      Max_Size : Boolean := False) return GL_Value
     renames LLVM_Size.Get_Array_Type_Size;

   --  Here we instantiate the size routines with functions that compute
   --  whether a size is dynamic or not and make those visible to clients.

   package IDS_Size is
      new Size (Result           => IDS,
                Empty_Result     => No_IDS,
                Sz_Const         => Const,
                Sz_Const_Int     => Const_Int,
                Sz_Type_Size     => Get_Type_Size,
                "+"              => "+",
                "-"              => "-",
                "*"              => "*",
                "/"              => "/",
                Sz_I_Cmp         => I_Cmp,
                Sz_S_Div         => S_Div,
                Sz_Neg           => Neg,
                Sz_Select        => Build_Select,
                Sz_Min           => Build_Min,
                Sz_Max           => Build_Max,
                Sz_Extract_Value => Extract_Value,
                Sz_Convert       => Convert,
                Sz_Emit_Expr     => Emit_Expr,
                Sz_Emit_Convert  => Emit_Convert,
                Sz_Is_Const      => Is_Const,
                Sz_Const_Val     => Const_Val_ULL,
                Sz_Undef         => Undef);

   function Get_Array_Type_Size
     (TE       : Entity_Id;
      V        : GL_Value;
      Max_Size : Boolean := False) return IDS
     renames IDS_Size.Get_Array_Type_Size;

   --  Here we instantiate the size routines with functions that compute
   --  the tree value for back-annotation.

   package BA_Size is
      new Size (Result           => BA_Data,
                Empty_Result     => No_BA,
                Sz_Const         => Const,
                Sz_Const_Int     => Const_Int,
                Sz_Type_Size     => Get_Type_Size,
                "+"              => "+",
                "-"              => "-",
                "*"              => "*",
                "/"              => "/",
                Sz_I_Cmp         => I_Cmp,
                Sz_S_Div         => S_Div,
                Sz_Neg           => Neg,
                Sz_Select        => Build_Select,
                Sz_Min           => Build_Min,
                Sz_Max           => Build_Max,
                Sz_Extract_Value => Extract_Value,
                Sz_Convert       => Convert,
                Sz_Emit_Expr     => Emit_Expr,
                Sz_Emit_Convert  => Emit_Convert,
                Sz_Is_Const      => Is_Const,
                Sz_Const_Val     => Const_Val_ULL,
                Sz_Undef         => Undef);

   function Get_Array_Type_Size
     (TE       : Entity_Id;
      V        : GL_Value;
      Max_Size : Boolean := False) return BA_Data
     renames BA_Size.Get_Array_Type_Size;

   function Bounds_To_Length
     (In_Low, In_High : BA_Data;
      GT              : GL_Type;
      Not_Superflat   : Boolean := False) return BA_Data
     renames BA_Size.Bounds_To_Length;

   -------------------------
   -- Array_Not_Superflat --
   -------------------------

   function Array_Not_Superflat (TE : Entity_Id; Dim : Nat) return Boolean is
     (Array_Info.Table (Get_Array_Info (TE) + Dim).Not_Superflat);

   -------------------------------
   -- Get_Array_Size_Complexity --
   -------------------------------

   function Get_Array_Size_Complexity
     (TE : Entity_Id; Max_Size : Boolean := False) return Nat
   is
      Info_Idx : constant Array_Info_Id := Get_Array_Info (TE);

   begin
      return Complexity : Nat :=
        Get_Type_Size_Complexity (Full_Component_GL_Type (TE), True)
      do
         for Dim in 0 .. Number_Dimensions (TE) - 1 loop
            declare
               Dim_Info : constant Index_Bounds :=
                 Array_Info.Table (Info_Idx + Dim);
            begin
               Complexity := (Complexity +
                                Bound_Complexity (Dim_Info.Low, Max_Size) +
                                Bound_Complexity (Dim_Info.High, Max_Size));
            end;
         end loop;
      end return;
   end Get_Array_Size_Complexity;

   --------------------
   -- Get_Bound_Size --
   --------------------

   function Get_Bound_Size (GT : GL_Type) return GL_Value is
      T : constant Type_T := Create_Array_Bounds_Type (Full_Etype (GT));
   begin
      return Align_To (Get_Type_Size (T), Get_Type_Alignment (T),
                       Get_Type_Alignment (GT));
   end Get_Bound_Size;

   -------------------------
   -- Get_Bound_Alignment --
   -------------------------

   function Get_Bound_Alignment (TE : Entity_Id) return Nat is
      (Get_Type_Alignment (Create_Array_Bounds_Type (TE)));

   ------------------------------
   -- Get_Array_Type_Alignment --
   ------------------------------

   function Get_Array_Type_Alignment (TE : Entity_Id) return Nat is
      Comp_GT    : constant GL_Type := Full_Component_GL_Type (TE);
      Comp_Align : constant Nat     := Get_Type_Alignment (Comp_GT);
      Comp_Size  : constant GL_Value :=
        (if   Is_Dynamic_Size (Comp_GT) then No_GL_Value
         else Get_Type_Size (Comp_GT, No_Padding => True));

   begin
      --  The alignment of an array type is the alignment of the component
      --  type unless it's packed by us (not a front-end created packed
      --  array) or a component size isn't a multiple of its alignment.

      if Is_Packed_Array_Impl_Type (TE)
        or else Is_Dynamic_Size (Comp_GT)
        or else (not Is_Packed (TE) and then Comp_Size mod Comp_Align = 0)
      then
         return Comp_Align;

      --  We now know that it's back-end packed.  If an alignment was
      --  specified, use it.

      elsif Known_Alignment (TE) then
         return UI_To_Int (Alignment (TE)) * BPU;

      else
         if Comp_Size mod Comp_Align = 0 then
            return Comp_Align;

         else
            --  Otherwise, find the largest alignment that divides the size

            return Align : Nat := BPU do
               while Comp_Size mod (Align * 2) = 0 loop
                  Align := Align * 2;
               end loop;
            end return;
         end if;
      end if;

   end Get_Array_Type_Alignment;

   ------------------------
   -- Maybe_Store_Bounds --
   ------------------------

   procedure Maybe_Store_Bounds
     (Dest, Src : GL_Value; Src_GT : GL_Type; For_Unconstrained : Boolean)
   is
      Dest_GT : constant GL_Type := Related_Type (Dest);

   begin
      --  Only do anything if the destination has a nominal constrained
      --  subtype or (if we're asked) if it has an unconstrained type.

      if Type_Needs_Bounds (Dest_GT)
        or else (For_Unconstrained and then not Is_Constrained (Dest_GT))
      then
         Store (Get_Array_Bounds (Src_GT, Src_GT, Src),
                Get (Dest, Reference_To_Bounds));
      end if;
   end Maybe_Store_Bounds;

   ---------------------------
   -- Data_Index_In_BD_Type --
   ---------------------------

   function Data_Index_In_BD_Type (V : GL_Value) return unsigned is
      T    : constant Type_T := Type_Of (V);
      BD_T : constant Type_T :=
        (if Is_Reference (V) then Get_Element_Type (T) else T);

   begin
      return Count_Struct_Element_Types (BD_T) - 1;
   end Data_Index_In_BD_Type;

   ---------------------------
   -- Contains_Discriminant --
   ---------------------------

   function Contains_Discriminant (N : Node_Id) return Boolean is

      function See_If_Discriminant (N : Node_Id) return Traverse_Result;
      --  Scan a single node looking for a discriminant

      function Scan is new Traverse_Func (See_If_Discriminant);
      --  Used to scan an expression looking for a discriminant

      -------------------------
      -- See_If_Discriminant --
      -------------------------

      function See_If_Discriminant (N : Node_Id) return Traverse_Result is
      begin
         --  If this is a component reference, we know there's no
         --  discriminant involved, but we don't want to be confused by
         --  the Selector here, so skip the node.

         if Nkind (N) = N_Selected_Component then
            return Skip;

         --  Otherwise, if this is not an N_Identifier or it has no
         --  Entity, we're not interested.

         elsif Nkind (N) /= N_Identifier or else No (Entity (N)) then
            return OK;

         --  If this is an actual discrminant, return and show that

         elsif Ekind (Entity (N)) = E_Discriminant then
            return Abandon;

         --  If this is a discrete or fixed-point type, see if either of
         --  the bounds involve a discriminant.

         elsif Is_Discrete_Or_Fixed_Point_Type (Entity (N)) then
            begin
               return (if Contains_Discriminant (Type_Low_Bound (Entity (N)))
                         or else (Contains_Discriminant
                                    (Type_High_Bound (Entity (N))))
                       then Abandon else OK);
            end;

         --  Otherwise, no discriminant in sight

         else
            return OK;

         end if;
      end See_If_Discriminant;

   begin
      return Scan (N) = Abandon;
   end Contains_Discriminant;

   ------------------------------
   -- Is_Self_Referential_Type --
   ------------------------------

   function Is_Self_Referential_Type (GT : GL_Type) return Boolean is
   begin
      --  Unconstrained types are always self-referential

      if not Is_Constrained (GT) then
         return True;

      --  If not array subtype, it isn't

      elsif Ekind (GT) /= E_Array_Subtype then
         return False;
      end if;

      --  Otherwise check each bound

      for Dim in 0 .. Number_Dimensions (GT) - 1 loop
         declare
            Dim_Info  : constant Index_Bounds :=
              Array_Info.Table (Get_Array_Info (Full_Etype (GT)) + Dim);
            Low_Expr  : constant Node_Id      := Dim_Info.Low.Value;
            High_Expr : constant Node_Id      := Dim_Info.High.Value;
         begin
            if (Present (Low_Expr) and then Contains_Discriminant (Low_Expr))
              or else (Present (High_Expr)
                         and then Contains_Discriminant (High_Expr))
            then
               return True;
            end if;
         end;
      end loop;

      return False;
   end Is_Self_Referential_Type;

   ---------------------------
   -- Emit_Others_Aggregate --
   ---------------------------

   procedure Emit_Others_Aggregate (LValue : GL_Value; N : Node_Id) is
      GT    : constant GL_Type := Primitive_GL_Type (Full_GL_Type (N));
      E     : Node_Id          :=
        Expression (First (Component_Associations (N)));
      Value : GL_Value;

   begin
      --  First, store the bounds if needed

      Maybe_Store_Bounds (LValue, No_GL_Value, GT, False);

      --  Find the innermost N_Aggregate and get the value to use

      while Nkind (E) = N_Aggregate and then Is_Others_Aggregate (E) loop
         E := Expression (First (Component_Associations (E)));
      end loop;

      --  If the type is floating-point, the front-end has verified that
      --  it's zero, so use that.  Otherwise, evaluate the value and
      --  convert it to a short short integer type.

      if Is_Floating_Point_Type (Full_Etype (E)) then
         Value := Const_Null (SSI_GL_Type);
      else
         Value := Emit_Convert_Value (E, SSI_GL_Type);
      end if;

      Call_With_Align
        (Build_Intrinsic (Memset, "llvm.memset.p0i8.i", Size_GL_Type),
         (1 => Pointer_Cast (Get (To_Primitive (LValue, No_Copy => True),
                                  Reference),
                             A_Char_GL_Type),
          2 => Value,
          3 => To_Bytes (Get_Type_Size (GT)),
          4 => (if Is_Volatile (LValue) then Const_True else Const_False)),
         Get_Type_Alignment (GT) / BPU);
   end Emit_Others_Aggregate;

   -----------------------------
   -- Emit_Constant_Aggregate --
   -----------------------------

   function Emit_Constant_Aggregate
     (N : Node_Id; Comp_Type, GT : GL_Type; Dims_Left : Nat) return GL_Value
   is
      Prim_GT : constant GL_Type := Primitive_GL_Type (GT);
      Idx     : Int              := 1;
      Vals    : GL_Value_Array (1 .. List_Length (Expressions (N)));
      Expr    : Node_Id;

   begin
      Expr := First (Expressions (N));
      while Present (Expr) loop
         Vals (Idx) :=
           (if   Dims_Left = 1 then Emit_Convert_Value (Expr, Comp_Type)
            else Emit_Constant_Aggregate (Expr, Comp_Type, Any_Array_GL_Type,
                                          Dims_Left - 1));
         Idx        := Idx + 1;
         Next (Expr);
      end loop;

      return From_Primitive (Const_Array (Vals, Prim_GT), GT);
   end Emit_Constant_Aggregate;

   ------------------
   -- Swap_Indices --
   ------------------

   function Swap_Indices
     (Idxs : GL_Value_Array; V : GL_Value) return GL_Value_Array is
   begin
      if Convention (Related_Type (V)) /= Convention_Fortran then
         return Idxs;
      end if;

      return Result : GL_Value_Array (Idxs'Range) do
         for J in Idxs'Range loop
            Result (J) := Idxs (Idxs'Last + Idxs'First - J);
         end loop;
      end return;
   end Swap_Indices;

   --------------------------
   -- Emit_Array_Aggregate --
   --------------------------

   function Emit_Array_Aggregate
     (N              : Node_Id;
      Dims_Left      : Pos;
      Indices_So_Far : GL_Value_Array;
      Value_So_Far   : GL_Value) return GL_Value
   is
      GT        : constant GL_Type := Primitive_GL_Type (Full_GL_Type (N));
      Comp_GT   : constant GL_Type := Full_Component_GL_Type (GT);
      Cur_Index : GL_Value         := Size_Const_Null;
      Expr      : Node_Id;

   begin
      --  The back-end supports exactly two types of array aggregates.
      --  One, which we handle here, is for a fixed-size aggregate.  The
      --  other are very special cases of Others that are tested for in
      --  Aggr_Assignment_OK_For_Backend in Exp_Aggr.

      --  This may be an Others aggregate if it's not directly on the RHS
      --  of an assignment statement, for example if we're assigning such
      --  to a bitfield.  So handle it here.

      if Is_Others_Aggregate (N) then

         --  If we've already been passed in an LHS, use it.  Otherwise,
         --  allocate one.

         declare
            Result : constant GL_Value :=
              (if   Present (Value_So_Far) then Value_So_Far
               else Allocate_For_Type (GT, GT, N));

         begin
            Emit_Others_Aggregate (Result, N);
            return Result;
         end;

      --  Handle the case where we have all constants.  In that case, it's
      --  better to just make the array directly.  The test here checks for
      --  multi-dimensional Fortran arrays, which we don't handle.
      --  However, we can only do this if we're either at the top level of
      --  the array or the type is loadable.

      elsif Is_No_Elab_Needed (N)
        and then (Is_Loadable_Type (GT)
                    or else Dims_Left = Number_Dimensions (GT))
      then
         return Emit_Constant_Aggregate (N, Comp_GT, GT, Dims_Left);
      end if;

      --  Otherwise we have a normal aggregate

      Expr := First (Expressions (N));
      return Cur_Value : GL_Value := Value_So_Far do

         --  If we haven't already made a value, do so now.  If this is
         --  a loadable type or we have a value, we start with an undef
         --  of that type.  Otherwise, it's a variable of that type.  We
         --  already handled the constant case above.

         if No (Cur_Value) then
            if Is_Loadable_Type (GT)
              and then not Is_Unconstrained_Record (Comp_GT)
            then
               Cur_Value := Get_Undef (GT);
            else
               Cur_Value := Allocate_For_Type (GT, GT, N);
            end if;
         end if;

         --  Now process each expression

         while Present (Expr) loop
            declare
               Idxs   : constant GL_Value_Array :=
                 Indices_So_Far & GL_Value_Array'(1 => Cur_Index);
               Result : GL_Value                := No_GL_Value;

            begin
               --  If this is a nested N_Aggregate and we have dimensions
               --  left in the outer array, use recursion to fill in the
               --  aggregate.

               if Nkind_In (Expr, N_Aggregate, N_Extension_Aggregate)
                 and then Dims_Left > 1
               then
                  Cur_Value := Emit_Array_Aggregate (Expr, Dims_Left - 1, Idxs,
                                                     Cur_Value);

               --  Otherwise do an indexed store

               else
                  Result :=
                    Build_Indexed_Store (Cur_Value,
                                         Swap_Indices (Idxs, Cur_Value),
                                         Emit_Convert_Value (Expr, Comp_GT));
                  if Present (Result) then
                     Cur_Value := Result;
                  end if;
               end if;
            end;

            Cur_Index := Cur_Index + 1;
            Next (Expr);
         end loop;
      end return;
   end Emit_Array_Aggregate;

   ----------------------
   -- Get_Array_Bounds --
   ----------------------

   function Get_Array_Bounds
     (GT, V_GT : GL_Type; V : GL_Value) return GL_Value
   is
      Info_Idx : constant Array_Info_Id :=
        (if   Is_Packed_Array_Impl_Type (GT)
         then Get_Orig_Array_Info (Full_Etype (GT))
         else Get_Array_Info (Full_Etype (GT)));
      N_Dim    : constant Nat           :=
        (Number_Dimensions (if   Is_Packed_Array_Impl_Type (GT)
                            then Full_Original_Array_Type (GT)
                            else Full_Etype (GT)));

   begin
      return Bound_Val : GL_Value := Get_Undef_Relationship (GT, Bounds) do
         for Dim in Nat range 0 .. N_Dim - 1 loop
            declare
               --  The type of the bound of the array we're using for the
               --  bounds may not be the same as the type of the bound in
               --  the unconstrained array, so be sure to convert
               --  (C46042A).

               Bound_GT             : constant GL_Type :=
                 Array_Info.Table (Info_Idx + Dim).Bound_GT;
               Low_Bound            : constant GL_Value  :=
                 Get_Array_Bound (V_GT, Dim, True, V,
                                  For_Orig =>
                                    Is_Packed_Array_Impl_Type (V_GT));
               High_Bound           : constant GL_Value  :=
                 Get_Array_Bound (V_GT, Dim, False, V,
                                  For_Orig =>
                                    Is_Packed_Array_Impl_Type (V_GT));
               Converted_Low_Bound  : constant GL_Value  :=
                 Convert (Low_Bound, Bound_GT);
               Converted_High_Bound : constant GL_Value  :=
                 Convert (High_Bound, Bound_GT);

            begin
               Bound_Val := Insert_Value
                 (Bound_Val, Converted_Low_Bound, (1 => unsigned (Dim * 2)));

               Bound_Val := Insert_Value
                 (Bound_Val, Converted_High_Bound,
                  (1 => unsigned (Dim * 2 + 1)));
            end;
         end loop;
      end return;
   end Get_Array_Bounds;

   -----------------------
   -- Get_GEP_Safe_Type --
   -----------------------

   function Get_GEP_Safe_Type (V : GL_Value) return GL_Type is
      Int_Types : constant array (Nat range <>) of GL_Type :=
        (SSI_GL_Type, SI_GL_Type, Integer_GL_Type, LI_GL_Type, LLI_GL_Type);
      Our_GT  : constant GL_Type                           := Related_Type (V);

   begin
      --  If we are of an unsigned type narrower than Size_Type, we must find
      --  a wider type to use.  We use the first, which will be the narrowest.

      if not Is_Unsigned_Type (Our_GT)
        or else RM_Size (Our_GT) >= RM_Size (Size_GL_Type)
      then
         return Our_GT;
      end if;

      for GT of Int_Types loop
         if RM_Size (GT) > RM_Size (Our_GT) then
            return GT;
         end if;
      end loop;

      return No_GL_Type;
   end Get_GEP_Safe_Type;

   -----------------
   -- Get_Indices --
   -----------------

   function Get_Indices
     (Indices : List_Id; V : GL_Value) return GL_Value_Array
   is
      GT         : constant GL_Type := Related_Type (V);
      N_Dim      : constant Int     := Number_Dimensions (GT);
      Fortran    : constant Boolean := Convention (GT) = Convention_Fortran;
      Idx        : Nat              := (if Fortran then N_Dim else 1);
      Dim        : Nat              := 0;
      Idxs       : GL_Value_Array (1 .. N_Dim);
      N          : Node_Id;

   begin
      N := First (Indices);
      while Present (N) loop

         --  Adjust the index according to the range lower bound.  If the
         --  type is an unconstrained PAT, we skip this adjustment.

         declare
            User_Index          : constant GL_Value := Emit_Safe_Expr (N);
            Dim_Low_Bound       : constant GL_Value :=
              (if   Is_Packed_Array_Impl_Type (GT)
                    and then not Is_Constrained (GT)
               then Const_Null (User_Index)
               else Get_Array_Bound (GT, Dim, True, V));
            Dim_Op_GT           : constant GL_Type  :=
              Get_GEP_Safe_Type (Dim_Low_Bound);
            Converted_Index     : constant GL_Value :=
              Convert (User_Index, Dim_Op_GT);
            Converted_Low_Bound : constant GL_Value :=
              Convert (Dim_Low_Bound, Dim_Op_GT);

         begin
            Idxs (Idx) := Converted_Index - Converted_Low_Bound;
         end;

         Idx := (if Fortran then Idx - 1 else Idx + 1);
         Dim := Dim + 1;
         Next (N);
      end loop;

      return Idxs;
   end Get_Indices;

   ------------------------
   -- Get_Indexed_LValue --
   ------------------------

   function Get_Indexed_LValue
     (Idxs : GL_Value_Array; V : GL_Value) return GL_Value
   is
      GT         : constant GL_Type  := Related_Type (V);
      N_Dim      : constant Int      := Number_Dimensions (GT);
      Comp_GT    : constant GL_Type  := Full_Component_GL_Type (GT);
      Array_Data : constant GL_Value :=
        Get (To_Primitive (V, No_Copy => True), Reference);
      Fortran    : constant Boolean  := Convention (GT) = Convention_Fortran;

   begin
      if not Is_Nonnative_Type (GT) then
         return Mark_Atomic
           (Mark_Volatile
              (GEP (Comp_GT, Array_Data,
                    GL_Value_Array'(1 => Size_Const_Null) & Idxs),
               Has_Volatile_Components (GT)),
            Has_Atomic_Components (GT));
      end if;

      --  Otherwise, we choose a type to use for the indexing.  If the
      --  component type is of fixed size, the array type must be [0 x
      --  CT], and we can count in units of CT.  If CT is of variable
      --  size, we convert the array data type to an i8*, do the
      --  indexing computation in units of bytes, and then convert
      --  back to the array type.  We start with the first index then
      --  for each dimension after the first, multiply by the size of
      --  that dimension and add that index.  Finally, we multiply by
      --  the size of the component type if it isn't the indexing
      --  type.  We do all of this in Size_Type.  Getting the indexing here
      --  correct for the Fortran and non-Fortran cases are tricky.

      declare
         Comp_Unc  : constant Boolean  := Is_Unconstrained_Record (Comp_GT);
         Use_Comp  : constant Boolean  := Is_Native_Component_GT (Comp_GT);
         Unit_GT   : constant GL_Type  :=
           (if Use_Comp then Comp_GT else SSI_GL_Type);
         Data      : constant GL_Value :=
           Get (Ptr_To_Ref (Array_Data, Unit_GT), Reference);
         Unit_Mult : constant GL_Value :=
           (if   Use_Comp then Size_Const_Int (Uint_1)
            else To_Bytes (Get_Type_Size (Comp_GT, Max_Size => Comp_Unc)));
         Index     : GL_Value          := To_Size_Type (Idxs (1));
         Dim       : Int               := (if Fortran then N_Dim - 2 else 1);

      begin
         for Idx in 2 .. Idxs'Last loop
            Index := Index * Get_Array_Length (Full_Etype (GT), Dim, V) +
                      To_Size_Type (Idxs (Idx));
            Dim   := (if Fortran then Dim - 1 else Dim + 1);
         end loop;

         Index := Index * Unit_Mult;
         return Ptr_To_Ref
           (Mark_Volatile
              (GEP (Unit_GT, Data, (1 => Index), "arr-lvalue"),
               Has_Volatile_Components (GT)),
            Comp_GT);
      end;

   end Get_Indexed_LValue;

   ----------------------
   -- Get_Slice_LValue --
   ----------------------

   function Get_Slice_LValue (GT : GL_Type; V : GL_Value) return GL_Value
   is
      Rng         : constant Node_Id  := Get_Dim_Range (First_Index (GT));
      Array_Data  : constant GL_Value :=
        Get (To_Primitive (V, No_Copy => True), Reference);
      Arr_GT      : constant GL_Type  := Full_Designated_GL_Type (V);
      Idx_LB      : constant GL_Value := Get_Array_Bound (Arr_GT, 0, True, V);
      Index_Val   : constant GL_Value := Emit_Safe_Expr (Low_Bound (Rng));
      Dim_Op_GT   : constant GL_Type  := Get_GEP_Safe_Type (Idx_LB);
      Cvt_Index   : constant GL_Value := Convert (Index_Val, Dim_Op_GT);
      Cvt_LB      : constant GL_Value := Convert (Idx_LB, Dim_Op_GT);
      Index_Shift : constant GL_Value := Cvt_Index - Cvt_LB;
      --  Compute how much we need to offset the array pointer. Slices
      --  can be built only on single-dimension arrays

   begin
      --  Like in Get_Indexed_LValue, we have to hande both the fake and
      --  non-fake cases.  Luckily, we know we're only a single dimension.
      --  However, GEP's result type is a pointer to the component type, so
      --  we need to cast to the result (array) type in both cases.

      if not Is_Nonnative_Type (Arr_GT) then
         return Ptr_To_Ref (GEP (GT, Array_Data,
                                 (1 => Size_Const_Null, 2 => Index_Shift),
                                 "arr-lvalue"),
                            GT);
      end if;

      declare
         Comp_GT   : constant GL_Type  := Full_Component_GL_Type (Arr_GT);
         Comp_Unc  : constant Boolean  := Is_Unconstrained_Record (Comp_GT);
         Use_Comp  : constant Boolean  := Is_Native_Component_GT (Comp_GT);
         Unit_GT   : constant GL_Type  :=
           (if Use_Comp then Comp_GT else SSI_GL_Type);
         Data      : constant GL_Value :=
           Get (Ptr_To_Ref (Array_Data, Unit_GT), Reference);
         Unit_Mult : constant GL_Value :=
           (if   Use_Comp then Size_Const_Int (Uint_1)
            else To_Bytes (Get_Type_Size (Comp_GT, Max_Size => Comp_Unc)));
         Index     : constant GL_Value :=
           To_Size_Type (Index_Shift) * Unit_Mult;

      begin
         return Ptr_To_Ref
           (GEP (Arr_GT, Data, (1 => Index), "arr-lvalue"), GT);
      end;

   end Get_Slice_LValue;

   ------------------------
   -- Build_Indexed_Load --
   ------------------------

   function Build_Indexed_Load
     (V          : GL_Value;
      Idxs       : GL_Value_Array;
      For_LHS    : Boolean := False;
      Prefer_LHS : Boolean := False;
      VFA        : Boolean := False) return GL_Value
   is
      Result : GL_Value := V;

   begin
      --  If V is Volatile_Full_Access, we have to try to load the full array
      --  into memory.  If we did, and this is for an LHS, we also need to
      --  set up a writeback.

      if VFA then
         Result := Get (Result, Object);
         if Is_Data (Result) and For_LHS then
            Result := Get (Result, Any_Reference);
            Add_Write_Back (V, Empty, Result);
         end if;
      end if;

      --  If we have something in a data form, we're not requiring or
      --  preferring an LHS, and all indices are constants, we can and
      --  should do this with an Extract_Value.

      if Is_Data (Result) and then not For_LHS and then not Prefer_LHS
        and then (for all J of Idxs => Is_A_Const_Int (J))
      then
         return Extract_Value (Full_Component_GL_Type (Result),
                               To_Primitive (Result),
                               Idxs_From_GL_Values (Idxs));
      else
         --  Otherwise, get a reference and do the indexing

         return Get_Indexed_LValue (Idxs, Get (Result, Any_Reference));
      end if;

   end Build_Indexed_Load;

   -------------------------
   -- Build_Indexed_Store --
   -------------------------

   function Build_Indexed_Store
     (In_LHS : GL_Value;
      Idxs   : GL_Value_Array;
      RHS    : GL_Value;
      VFA    : Boolean := False) return GL_Value
   is
      LHS    : GL_Value := In_LHS;
      Result : GL_Value := No_GL_Value;

   begin
      --  If this is for a volatile full access object, load that object

      if VFA and then not Is_Data (LHS) then
         LHS := Get (To_Primitive (LHS), Object);
      end if;

      --  Now use one of two stratgies, depending on whether or not we have
      --  data.

      if Is_Data (LHS) then
         Result := Insert_Value
           (LHS, RHS, Idxs_From_GL_Values (Swap_Indices (Idxs, LHS)));
      else
         Emit_Assignment (Get_Indexed_LValue (Idxs, LHS), Value => RHS);
      end if;

      return Result;
   end Build_Indexed_Store;

   -------------------------
   -- Build_Indexed_Store --
   -------------------------

   procedure Build_Indexed_Store
     (LHS  : GL_Value;
      Idxs : GL_Value_Array;
      RHS  : GL_Value;
      VFA  : Boolean := False)
   is
      Result : constant GL_Value := Build_Indexed_Store (LHS, Idxs, RHS, VFA);

   begin
      --  If we have a value, copy it back into LHS

      if Present (Result) then
         Emit_Assignment (LHS, Value => Result);
      end if;
   end Build_Indexed_Store;

   -------------------
   -- Get_Dim_Range --
   -------------------

   function Get_Dim_Range (N : Node_Id) return Node_Id is
   begin
      case Nkind (N) is
         when N_Range
            | N_Signed_Integer_Type_Definition
            | N_Real_Range_Specification =>
            return N;
         when N_Identifier | N_Expanded_Name =>
            return Get_Dim_Range (Scalar_Range (Full_Entity (N)));

         when N_Defining_Identifier =>
            return Get_Dim_Range (Scalar_Range (N));

         when N_Subtype_Indication =>
            declare
               Constr : constant Node_Id := Constraint (N);
            begin
               if Present (Constr) then
                  pragma Assert (Nkind (Constr) = N_Range_Constraint);
                  return Get_Dim_Range (Range_Expression (Constr));
               else
                  return
                    Get_Dim_Range (Scalar_Range
                                     (Full_Entity (Subtype_Mark (N))));
               end if;
            end;

         when others =>
            null;
      end case;

      pragma Assert (False);
   end Get_Dim_Range;
end GNATLLVM.Arrays;
