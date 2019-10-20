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

with LLVM.Core; use LLVM.Core;

with GNATLLVM.GLValue; use GNATLLVM.GLValue;

package GNATLLVM.Aliasing is

   procedure Initialize;
   --  Perform initialization for this compilation

   procedure Record_TBAA_For_Type (TE : Entity_Id)
     with Pre => Is_Type_Or_Void (TE);
   --  Compute and record the TBAA for TE

   procedure Add_Aliasing_To_Instruction (Inst : Value_T; V : GL_Value)
     with Pre => Present (Is_A_Instruction (Inst)) and then Present (V);
   --  Add aliasing information from V to Inst

end GNATLLVM.Aliasing;