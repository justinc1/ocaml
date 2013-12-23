(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* Pseudo-registers *)

type raw_name =
  | Anon
  | R
  | Named of string

type t =
  { mutable raw_name: raw_name;         (* Name (for printing) *)
    stamp: int;                         (* Unique stamp *)
    typ: Cmm.machtype_component;        (* Type of contents *)
    mutable loc: location;              (* Actual location *)
    mutable spill: bool;                (* "true" to force stack allocation  *)
    mutable interf: t list;             (* Other regs live simultaneously *)
    mutable prefer: (t * int) list;     (* Preferences for other regs *)
    mutable degree: int;                (* Number of other regs live sim. *)
    mutable spill_cost: int;            (* Estimate of spilling cost *)
    mutable visited: bool;              (* For graph walks *)
    mutable partial_value : int option; (* Which part of a value (0-based), if any *)
    mutable is_parameter: int option;   (* Function parameter index (0-based), if any *)
  }

and location =
    Unknown
  | Reg of int
  | Stack of stack_location

and stack_location =
    Local of int
  | Incoming of int
  | Outgoing of int

val dummy: t
val create: Cmm.machtype_component -> t
val createv: Cmm.machtype -> t array
val createv_like: t array -> t array
val clone: t -> t
val at_location: Cmm.machtype_component -> location -> t
val same_location: t -> t -> bool

module Set: Set.S with type elt = t
module Map: Map.S with type key = t

val add_set_array: Set.t -> t array -> Set.t
val diff_set_array: Set.t -> t array -> Set.t
val inter_set_array: Set.t -> t array -> Set.t
val set_of_array: t array -> Set.t

val reset: unit -> unit
val all_registers: unit -> t list
val all_registers_set: unit -> Set.t
val num_registers: unit -> int
val reinit: unit -> unit

val anonymous : t -> bool
val has_name_suitable_for_debugger : t -> bool
val name_for_printing : t -> string
val location : t -> location

val set_is_parameter : t -> parameter_index:int -> unit
val is_parameter : t -> int option

val with_name : t -> name:raw_name -> t
val with_name_from : t -> from:t -> t
val with_name_fromv : t array -> from:t array -> t array

val stamp : t -> int
