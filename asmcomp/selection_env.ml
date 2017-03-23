(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                     Mark Shinwell, Jane Street Europe                  *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*   Copyright 2017 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

type t = {
  vars : (Ident.t, Reg.t array) Tbl.t;
  immutable_vars : Ident.Set.t;
  static_exceptions : (int, Reg.t array list) Tbl.t;
}

let empty = {
  vars = Tbl.empty;
  immutable_vars = Ident.Set.empty;
  static_exceptions = Tbl.empty;
}

let add id v ~immutable env =
  let immutable_vars =
    if immutable then Ident.Set.add id env.immutable_vars
  in
  { env with vars = Tbl.add id v env.vars }

let add_static_exception id v env =
  { env with static_exceptions = Tbl.add id v env.static_exceptions }

let find id env =
  Tbl.find id env.vars

let find_static_exception id env =
  Tbl.find id env.static_exceptions
