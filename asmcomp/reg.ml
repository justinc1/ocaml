(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

open Cmm

type shared = {
  mutability : Cmm.mutability;
  stamp: int;
  mutable typ: Cmm.machtype_component;
  mutable loc: location;
  mutable spill: bool;
  mutable part: int option;
  mutable is_parameter: int option;
  mutable interf: shared list;
  mutable prefer: (shared * int) list;
  mutable degree: int;
  mutable spill_cost: int;
  mutable visited: bool;
}

and location =
    Unknown
  | Reg of int
  | Stack of stack_location

and stack_location =
    Local of int
  | Incoming of int
  | Outgoing of int

type t = {
  mutable name : Ident.t option;
  mutable propagate_name_to : t option;
  shared : shared;
  dummy : (unit -> unit);
}

type reg = t

let dummy =
  let shared =
    { mutability = Cmm.Immutable; is_parameter = None;
      stamp = 0; typ = Int; loc = Unknown;
      spill = false; interf = []; prefer = []; degree = 0; spill_cost = 0;
      visited = false; part = None;
    }
  in
  { name = None;
    propagate_name_to = None;
    shared;
    dummy = (fun () -> ());
  }

let currstamp = ref 0
let reg_list = ref([] : shared list)

let create ?(mutability = Cmm.Immutable) ty =
  let shared =
    { mutability; stamp = !currstamp; typ = ty; is_parameter = None;
      loc = Unknown; spill = false; interf = []; prefer = []; degree = 0;
      spill_cost = 0; visited = false; part = None; } in
  reg_list := shared :: !reg_list;
  incr currstamp;
  { name = None;
    propagate_name_to = None;
    shared;
    dummy = (fun () -> ());
  }

let createv tyv =
  let n = Array.length tyv in
  let rv = Array.make n dummy in
  for i = 0 to n-1 do rv.(i) <- create tyv.(i) done;
  rv

let createv_like ?mutability rv =
  let n = Array.length rv in
  let rv' = Array.make n dummy in
  for i = 0 to n-1 do rv'.(i) <- create ?mutability rv.(i).shared.typ done;
  rv'

let clone r =
  let nr = create r.shared.typ ~mutability:r.shared.mutability in
  nr.name <- r.name;
  nr.shared.is_parameter <- r.shared.is_parameter;
  nr

(* The name of registers created in [Proc]. *)
let proc_reg_name = Ident.create_persistent "R"

let at_location ty loc =
  let shared = { mutability = Cmm.Immutable; is_parameter = None;
            stamp = !currstamp; typ = ty; loc;
            spill = false; interf = []; prefer = []; degree = 0;
            spill_cost = 0; visited = false; part = None; } in
  incr currstamp;
  { name = Some proc_reg_name;
    propagate_name_to = None;
    shared;
    dummy = (fun () -> ());
  }

let immutable t =
  match t.shared.mutability with
  | Immutable -> true
  | Mutable -> false

let name t =
  match t.name with
  | None -> ""
  | Some ident ->
    let name = Ident.unique_name ident in
    let with_spilled =
      if t.shared.spill then
        "spilled-" ^ name
      else
        name
    in
    match t.shared.part with
    | None -> with_spilled
    | Some part -> with_spilled ^ "#" ^ string_of_int part

let anonymous t =
  match t.name with
  | None -> true
  | Some _ident -> false

let anonymise t =
  if not (immutable t) then begin
    Misc.fatal_error "Reg.rename: attempt to rename mutable register"
  end;
  { t with
    name = None;
    propagate_name_to = None;
  }

let rename t name =
  if not (immutable t) then begin
    Misc.fatal_error "Reg.rename: attempt to rename mutable register"
  end;
  { t with
    name;
    propagate_name_to = None;
  }

let renamev ts name = Array.map (fun t -> rename t name) ts

let set_name t name =
  t.name <- name;
  match t.propagate_name_to with
  | None -> ()
  | Some t' -> t'.name <- name

let identical_except_in_name r ~take_name_from =
  let shared = {
    mutability = r.shared.mutability;
    stamp = r.shared.stamp;
    typ = r.shared.typ;
    loc = r.shared.loc;
    spill = r.shared.spill;
    part = r.shared.part;
    is_parameter = r.shared.is_parameter;
    interf = r.shared.interf;
    prefer = r.shared.prefer;
    degree = r.shared.degree;
    spill_cost = r.shared.spill_cost;
    visited = r.shared.visited;
  }
  in
  { name = take_name_from.name;
    propagate_name_to = None;
    shared;
    dummy = (fun () -> ());
  }

let identical_except_in_namev rs ~take_names_from =
  if Array.length rs <> Array.length take_names_from then
    failwith "Reg.identical_except_in_namev with different length arrays";
  Array.init (Array.length rs) (fun index ->
    identical_except_in_name rs.(index)
      ~take_name_from:take_names_from.(index))

let first_virtual_reg_stamp = ref (-1)

let reset() =
  (* When reset() is called for the first time, the current stamp reflects
     all hard pseudo-registers that have been allocated by Proc, so
     remember it and use it as the base stamp for allocating
     soft pseudo-registers *)
  if !first_virtual_reg_stamp = -1 then first_virtual_reg_stamp := !currstamp;
  currstamp := !first_virtual_reg_stamp;
  reg_list := []

let all_registers() = !reg_list
let num_registers() = !currstamp

let reinit_reg shared =
  shared.loc <- Unknown;
  shared.interf <- [];
  shared.prefer <- [];
  shared.degree <- 0;
  (* Preserve the very high spill costs introduced by the reloading pass *)
  if shared.spill_cost >= 100000
  then shared.spill_cost <- 100000
  else shared.spill_cost <- 0

let reinit() =
  List.iter reinit_reg !reg_list

module RegOrder =
  struct
    type t = reg
    let compare r1 r2 = r1.shared.stamp - r2.shared.stamp
  end

module RegOrder_distinguishing_names =
  struct
    type t = reg
    let compare r1 r2 =
      let c =
        match r1.name, r2.name with
        | None, None -> 0
        | None, Some _ -> -1
        | Some _, None -> 1
        | Some name1, Some name2 -> Ident.compare name1 name2
      in
      if c <> 0 then c
      else RegOrder.compare r1 r2
  end

module Set_distinguishing_names = Set.Make(RegOrder_distinguishing_names)
module Map_distinguishing_names = Map.Make(RegOrder_distinguishing_names)
module Set = Set.Make(RegOrder)
module Map = Map.Make(RegOrder)

let add_set_array s v =
  match Array.length v with
    0 -> s
  | 1 -> Set.add v.(0) s
  | n -> let rec add_all i =
           if i >= n then s else Set.add v.(i) (add_all(i+1))
         in add_all 0

let diff_set_array s v =
  match Array.length v with
    0 -> s
  | 1 -> Set.remove v.(0) s
  | n -> let rec remove_all i =
           if i >= n then s else Set.remove v.(i) (remove_all(i+1))
         in remove_all 0

let inter_set_array s v =
  match Array.length v with
    0 -> Set.empty
  | 1 -> if Set.mem v.(0) s
         then Set.add v.(0) Set.empty
         else Set.empty
  | n -> let rec inter_all i =
           if i >= n then Set.empty
           else if Set.mem v.(i) s then Set.add v.(i) (inter_all(i+1))
           else inter_all(i+1)
         in inter_all 0

let disjoint_set_array s v =
  match Array.length v with
    0 -> true
  | 1 -> not (Set.mem v.(0) s)
  | n -> let rec disjoint_all i =
           if i >= n then true
           else if Set.mem v.(i) s then false
           else disjoint_all (i+1)
         in disjoint_all 0

let set_of_array v =
  match Array.length v with
    0 -> Set.empty
  | 1 -> Set.add v.(0) Set.empty
  | n -> let rec add_all i =
           if i >= n then Set.empty else Set.add v.(i) (add_all(i+1))
         in add_all 0

let holds_pointer t =
  match t.shared.typ with
  | Addr | Val -> true
  | Int | Float -> false

let holds_non_pointer t = not (holds_pointer t)

let assigned_to_stack t =
  match t.shared.loc with
  | Stack _ -> true
  | Reg _ | Unknown -> false
