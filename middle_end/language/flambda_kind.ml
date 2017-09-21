(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2017 OCamlPro SAS                                          *)
(*   Copyright 2017 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

type scanning =
  | Must_scan
  | Can_scan

let join_scanning s1 s2 =
  match s1, s2 with
  | Must_scan, Must_scan
  | Must_scan, Can_scan
  | Can_scan, Must_scan -> Must_scan
  | Can_scan, Can_scan -> Can_scan

type t =
  | Value of scanning
  | Naked_immediate
  | Naked_float
  | Naked_int32
  | Naked_int64
  | Naked_nativeint

let value ~must_scan =
  if must_scan then Value Must_scan else Value Can_scan

(* CR mshinwell: can remove lambdas now *)
let naked_immediate () = Naked_immediate

let naked_float () = Naked_float

let naked_int32 () = Naked_int32

let naked_int64 () = Naked_int64

let naked_nativeint () = Naked_nativeint

let lambda_value_kind t =
  let module L = Lambda in
  match t with
  | Value Must_scan -> Some L.Pgenval
  | Value Can_scan -> Some L.Pintval
  | Naked_immediate -> Some L.Pnaked_intval
  | Naked_float -> Some L.Pfloatval
  | Naked_int32 -> Some (L.Pboxedintval Pint32)
  | Naked_int64 -> Some (L.Pboxedintval Pint64)
  | Naked_nativeint -> Some (L.Pboxedintval Pnativeint)

include Identifiable.Make (struct
  type nonrec t = t

  let compare t1 t2 = Pervasives.compare t1 t2
  let equal t1 t2 = (compare t1 t2 = 0)

  let hash = Hashtbl.hash

  let print ppf t =
    match t with
    | Value Must_scan -> Format.pp_print_string ppf "value_must_scan"
    | Value Can_scan -> Format.pp_print_string ppf "value_can_scan"
    | Naked_immediate -> Format.pp_print_string ppf "naked_immediate"
    | Naked_float -> Format.pp_print_string ppf "naked_float"
    | Naked_int32 -> Format.pp_print_string ppf "naked_int32"
    | Naked_int64 -> Format.pp_print_string ppf "naked_int64"
    | Naked_nativeint -> Format.pp_print_string ppf "naked_nativeint"
end)

let compatible t1 t2 =
  match t1, t2 with
  | Value Must_can, Value_Can_scan
  | Value Can_scan, Value_Must_scan -> true
  | _, _ -> equal t1 t2