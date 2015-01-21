(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*                     Pierre Chambart, OCamlPro                       *)
(*                                                                     *)
(*  Copyright 2014 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

open Abstract_identifiers

(** Intermediate language used to perform closure conversion and inlining.
    See flambdatypes.ml for documentation.
*)

include module type of Flambdatypes

(** Access functions *)

val find_declaration :
  closure_id -> 'a function_declarations -> 'a function_declaration
(** [find_declaration f decl] raises [Not_found] if [f] is not in [decl]. *)

val find_declaration_variable :
  closure_id -> 'a function_declarations -> Variable.t
(** [find_declaration_variable f decl] raises [Not_found] if [f] is not in
    [decl]. *)

val find_free_variable :
  Var_within_closure.t -> 'a fset_of_closures -> 'a flambda
(** [find_free_variable v clos] raises [Not_found] if [c] is not in [clos]. *)

(** Utility functions *)

val function_arity : 'a function_declaration -> int

val variables_bound_by_the_closure :
  closure_id -> 'a function_declarations -> VarSet.t
(** Variables "bound by a closure" are those variables free in the
    corresponding function's body that are neither:
    - bound as parameters of that function; nor
    - bound by the [let] binding that introduces the function declaration(s).
    In particular, if [f], [g] and [h] are being introduced by a
    simultaneous, possibly mutually-recursive [let] binding then none of
    [f], [g] or [h] are bound in any of the closures for [f], [g] and [h].
*)

val can_be_merged : 'a flambda -> 'a flambda -> bool
(** If [can_be_merged f1 f2] is [true], it is safe to merge switch
    branches containing [f1] and [f2]. *)

val data_at_toplevel_node : 'a flambda -> 'a

val description_of_toplevel_node : 'a flambda -> string

val recursive_functions : 'a function_declarations -> VarSet.t

(** Sharing key *)
type sharing_key
val make_key : 'a flambda -> sharing_key option
