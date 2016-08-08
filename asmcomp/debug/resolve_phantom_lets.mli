(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                  Mark Shinwell, Jane Street Europe                     *)
(*                                                                        *)
(*   Copyright 2016 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(** Resolve transitive references to identifiers in the defining
    expressions of phantom lets.  Filter out phantom lets that will not
    be required due to inadequate provenance information or missing
    defining expressions. *)

val run
   : (Clambda.ulet_provenance option
        * Clambda.uphantom_defining_expr option) Ident.Map.t
  -> (Clambda.ulet_provenance option
        * Mach.phantom_defining_expr) Ident.Map.t