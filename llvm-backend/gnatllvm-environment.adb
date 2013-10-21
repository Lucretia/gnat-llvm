with Ada.Unchecked_Deallocation;

package body GNATLLVM.Environment is

   ----------------
   -- Push_Scope --
   ----------------

   procedure Push_Scope (Env : access Environ_Record) is
   begin
      Env.Scopes.Append (new Scope_Type'(others => <>));
   end Push_Scope;

   ---------------
   -- Pop_Scope --
   ---------------

   procedure Pop_Scope (Env : access Environ_Record) is
      procedure Free is new Ada.Unchecked_Deallocation (Scope_Type, Scope_Acc);
      Last_Scope : Scope_Acc := Env.Scopes.Last_Element;
   begin
      Free (Last_Scope);
      Env.Scopes.Delete_Last;
   end Pop_Scope;

   --------------
   -- Has_Type --
   --------------

   function Has_Type
     (Env : access Environ_Record; TE : Entity_Id) return Boolean
   is
      T : Type_T;
      pragma Unreferenced (T);
   begin
      T := Env.Get (TE);
      return True;
   exception
      when No_Such_Type =>
         return False;
   end Has_Type;

   ---------------
   -- Has_Value --
   ---------------

   function Has_Value
     (Env : access Environ_Record; VE : Entity_Id) return Boolean
   is
      V : Value_T;
      pragma Unreferenced (V);
   begin
      V := Env.Get (VE);
      return True;
   exception
      when No_Such_Value =>
         return False;
   end Has_Value;

   ---------
   -- Get --
   ---------

   function Get (Env : access Environ_Record; TE : Entity_Id) return Type_T is
      use Type_Maps;
   begin
      for S of reverse Env.Scopes loop
         declare
            C : constant Cursor := S.Types.Find (TE);
         begin
            if C /= No_Element then
               return Element (C);
            end if;
         end;
      end loop;
      raise No_Such_Type
        with "Cannot find a LLVM type for Entity #" & Entity_Id'Image (TE);
   end Get;

   ---------
   -- Get --
   ---------

   function Get (Env : access Environ_Record; VE : Entity_Id) return Value_T is
      use Value_Maps;
   begin
      for S of reverse Env.Scopes loop
         declare
            C : constant Cursor := S.Values.Find (VE);
         begin
            if C /= No_Element then
               return Element (C);
            end if;
         end;
      end loop;
      raise No_Such_Value
        with "Cannot find a LLVM value for Entity #" & Entity_Id'Image (VE);
   end Get;

   ---------
   -- Get --
   ---------

   function Get
     (Env : access Environ_Record; BE : Entity_Id) return Basic_Block_T is
   begin
      return Value_As_Basic_Block (Env.Get (BE));
   exception
      when No_Such_Value =>
         raise No_Such_Basic_Block;
   end Get;

   ---------
   -- Set --
   ---------

   procedure Set (Env : access Environ_Record; TE : Entity_Id; TL : Type_T) is
   begin
      Env.Scopes.Last_Element.Types.Include (TE, TL);
   end Set;

   ---------
   -- Set --
   ---------

   procedure Set (Env : access Environ_Record; VE : Entity_Id; VL : Value_T) is
   begin
      Env.Scopes.Last_Element.Values.Insert (VE, VL);
   end Set;

   ---------
   -- Set --
   ---------

   procedure Set
     (Env : access Environ_Record; BE : Entity_Id; BL : Basic_Block_T) is
   begin
      Env.Set (BE, Basic_Block_As_Value (BL));
   end Set;

   ---------------
   -- Push_Loop --
   ---------------

   procedure Push_Loop
     (Env : access Environ_Record;
      LE : Entity_Id;
      Exit_Point : Basic_Block_T) is
   begin
      Env.Exit_Points.Append ((LE, Exit_Point));
   end Push_Loop;

   --------------
   -- Pop_Loop --
   --------------

   procedure Pop_Loop (Env : access Environ_Record) is
   begin
      Env.Exit_Points.Delete_Last;
   end Pop_Loop;

   --------------------
   -- Get_Exit_Point --
   --------------------

   function Get_Exit_Point
     (Env : access Environ_Record; LE : Entity_Id) return Basic_Block_T is
   begin
      for Exit_Point of Env.Exit_Points loop
         if Exit_Point.Label_Entity = LE then
            return Exit_Point.Exit_BB;
         end if;
      end loop;

      --  If the loop label isn't registered, then we just met an exit
      --  statement with no corresponding loop: should not happen.
      raise Program_Error with "Unknown loop identifier";
   end Get_Exit_Point;

   --------------------
   -- Get_Exit_Point --
   --------------------

   function Get_Exit_Point
     (Env : access Environ_Record) return Basic_Block_T is
   begin
      return Env.Exit_Points.Last_Element.Exit_BB;
   end Get_Exit_Point;

   ---------------------
   -- Create_Function --
   ---------------------

   function Create_Subp
     (Env : access Environ_Record;
      Name : String; Typ : Type_T) return Subp_Env
   is
      Func : constant Value_T := Add_Function (Env.Mdl, Name, Typ);
      Subp : constant Subp_Env := new Subp_Env_Record'
        (Env           => Environ (Env),
         Func          => Func);
   begin
      Env.Subprograms.Append (Subp);
      Env.Current_Subps.Append (Subp);
      Position_Builder_At_End
        (Env.Bld, Env.Create_Basic_Block ("entry"));
      return Subp;
   end Create_Subp;

   ----------------
   -- Leave_Subp --
   ----------------

   procedure Leave_Subp (Env  : access Environ_Record) is
   begin
      Env.Current_Subps.Delete_Last;
   end Leave_Subp;

   ------------------
   -- Current_Subp --
   ------------------

   function Current_Subp (Env : access Environ_Record) return Subp_Env is
   begin
      return Env.Current_Subps.Last_Element;
   end Current_Subp;

   ------------------------
   -- Create_Basic_Block --
   ------------------------

   function Create_Basic_Block
     (Env : access Environ_Record; Name : String) return Basic_Block_T is
   begin
      return Append_Basic_Block_In_Context
        (Env.Ctx, Current_Subp (Env).Func, Name);
   end Create_Basic_Block;

end GNATLLVM.Environment;
