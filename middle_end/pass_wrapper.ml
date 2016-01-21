(**************************************************************************)
(*                                                                        *)
(*                                OCaml                                   *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2016 OCamlPro SAS                                    *)
(*   Copyright 2014--2016 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file ../LICENSE.       *)
(*                                                                        *)
(**************************************************************************)

let register ~pass_name =
  Clflags.all_passes := pass_name :: !Clflags.all_passes

let with_dump ~pass_name ~f ~input ~print_input ~print_output =
  let dump = List.mem pass_name !Clflags.dumped_passes_list in
  if dump then begin
    Format.eprintf "Before %s:@ %a@.@." pass_name print_input input
  end;
  let result = f () in
  match result with
  | None ->
    if dump then Format.eprintf "%s: no-op.\n%!" pass_name;
    None
  | Some result ->
    if dump then begin
      Format.eprintf "After%s:@ %a@.@." pass_name print_output result
    end;
    Some result
