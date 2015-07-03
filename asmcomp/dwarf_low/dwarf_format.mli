(***********************************************************************)
(*                                                                     *)
(*                               OCaml                                 *)
(*                                                                     *)
(*                 Mark Shinwell, Jane Street Europe                   *)
(*                                                                     *)
(*  Copyright 2014, Jane Street Holding                                *)
(*                                                                     *)
(*  Licensed under the Apache License, Version 2.0 (the "License");    *)
(*  you may not use this file except in compliance with the License.   *)
(*  You may obtain a copy of the License at                            *)
(*                                                                     *)
(*      http://www.apache.org/licenses/LICENSE-2.0                     *)
(*                                                                     *)
(*  Unless required by applicable law or agreed to in writing,         *)
(*  software distributed under the License is distributed on an        *)
(*  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,       *)
(*  either express or implied.  See the License for the specific       *)
(*  language governing permissions and limitations under the License.  *)
(*                                                                     *)
(***********************************************************************)

(* Whether we are emitting 32-bit or 64-bit DWARF.
   Note that this width does not necessarily coincide with the width of a
   native integer on the target processor.  (DWARF-4 standard section 7.4,
   page 142). *)

type t =
  | Thirty_two
  | Sixty_four

val set_size : t -> unit

(* Raises if [set_size] has not been called. *)
val size : unit -> t

module Int : sig
  (** An integer that has the same width as a given DWARF format. *)
  type t
end
