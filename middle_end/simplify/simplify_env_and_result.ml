(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2017 OCamlPro SAS                                    *)
(*   Copyright 2014--2017 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

module rec Env : sig
  include Simplify_env_and_result_intf.Env with type result = Result.t
end = struct
  type t = {
    backend : (module Backend_intf.S);
    simplify_toplevel:(
         t
      -> Simplify_result.t
      -> Flambda.Expr.t
      -> continuation:Continuation.t
      -> descr:string
      -> Flambda.Expr.t * Simplify_result.t);
    simplify_expr:(
         t
      -> Simplify_result.t
      -> Flambda.Expr.t
      -> Flambda.Expr.t * Simplify_result.t);
    simplify_apply_cont_to_cont:(
         ?don't_record_use:unit
      -> t
      -> Simplify_result.t
      -> Continuation.t
      -> arg_tys:Flambda_type.t list
      -> Continuation.t * Simplify_result.t);
    round : int;
    variables : Flambda_type.t Variable.Map.t;
    mutable_variables : Flambda_type.t Mutable_variable.Map.t;
    symbols : Flambda_type.Of_symbol.t Symbol.Map.t;
    continuations : Continuation_approx.t Continuation.Map.t;
    projections : Variable.t Projection.Map.t;
    current_functions : Set_of_closures_origin.Set.t;
    (* The functions currently being declared: used to avoid inlining
       recursively *)
    inlining_level : int;
    (* Number of times "inline" has been called recursively *)
    inside_branch : int;
    freshening : Freshening.t;
    never_inline : bool;
    never_inline_inside_closures : bool;
    never_inline_outside_closures : bool;
    allow_continuation_inlining : bool;
    allow_continuation_specialisation : bool;
    unroll_counts : int Set_of_closures_origin.Map.t;
    inlining_counts : int Closure_origin.Map.t;
    actively_unrolling : int Set_of_closures_origin.Map.t;
    closure_depth : int;
    inlining_stats_closure_stack : Inlining_stats.Closure_stack.t;
    inlined_debuginfo : Debuginfo.t;
  }

  let create ~never_inline ~allow_continuation_inlining
        ~allow_continuation_specialisation ~round ~backend
        ~simplify_toplevel ~simplify_expr ~simplify_apply_cont_to_cont =
    { backend;
      round;
      variables = Variable.Map.empty;
      mutable_variables = Mutable_variable.Map.empty;
      symbols = Symbol.Map.empty;
      continuations = Continuation.Map.empty;
      projections = Projection.Map.empty;
      current_functions = Set_of_closures_origin.Set.empty;
      inlining_level = 0;
      inside_branch = 0;
      freshening = Freshening.empty;
      never_inline;
      never_inline_inside_closures = false;
      never_inline_outside_closures = false;
      allow_continuation_inlining;
      allow_continuation_specialisation;
      unroll_counts = Set_of_closures_origin.Map.empty;
      inlining_counts = Closure_origin.Map.empty;
      actively_unrolling = Set_of_closures_origin.Map.empty;
      closure_depth = 0;
      inlining_stats_closure_stack =
        Inlining_stats.Closure_stack.create ();
      inlined_debuginfo = Debuginfo.none;
      simplify_toplevel;
      simplify_expr;
      simplify_apply_cont_to_cont;
    }

  let print ppf t =
    Format.fprintf ppf
      "Environment maps: %a@.Projections: %a@.Freshening: %a@.\
        Continuations: %a@.Currently inside functions: %a@.\
        Never inline: %b@.Never inline inside closures: %b@.\
        Never inline outside closures: %b@."
      Variable.Set.print (Variable.Map.keys t.variables)
      (Projection.Map.print Variable.print) t.projections
      Freshening.print t.freshening
      (Continuation.Map.print Continuation_approx.print) t.continuations
      Set_of_closures_origin.Set.print t.current_functions
      t.never_inline
      t.never_inline_inside_closures
      t.never_inline_outside_closures

  let backend t = t.backend
  let importer t = t.backend
  let round t = t.round
  let simplify_toplevel t = t.simplify_toplevel
  let simplify_expr t = t.simplify_expr
  let simplify_apply_cont_to_cont t = t.simplify_apply_cont_to_cont

  let local env =
    { env with
      variables = Variable.Map.empty;
      continuations = Continuation.Map.empty;
      projections = Projection.Map.empty;
      freshening = Freshening.empty_preserving_activation_state env.freshening;
      inlined_debuginfo = Debuginfo.none;
    }

  let mem t var = Variable.Map.mem var t.variables

  let add t var ty =
    let ty = Flambda_type.augment_with_variable ty var in
    let variables = Variable.Map.add var ty t.variables in
    { t with variables; }

  let add_mutable t mut_var ty =
    { t with mutable_variables =
      Mutable_variable.Map.add mut_var ty t.mutable_variables;
    }

  let find_symbol_exn t symbol =
    match Symbol.Map.find symbol t.symbols with
    | exception Not_found ->
      if Compilation_unit.equal
          (Compilation_unit.get_current_exn ())
          (Symbol.compilation_unit symbol)
      then begin
        Misc.fatal_errorf "Symbol %a from the current compilation unit is \
            unbound.  Maybe there is a missing [Let_symbol] or similar?"
          Symbol.print symbol
      end;
      Flambda_type.symbol_loaded_lazily symbol
    | ty -> ty

  let add_projection t ~projection ~bound_to =
    { t with
      projections =
        Projection.Map.add projection bound_to t.projections;
    }

  let find_projection t ~projection =
    match Projection.Map.find projection t.projections with
    | exception Not_found -> None
    | var -> Some var

  let add_continuation t cont ty =
    { t with
      continuations = Continuation.Map.add cont ty t.continuations;
    }

  let find_continuation t cont =
    match Continuation.Map.find cont t.continuations with
    | exception Not_found ->
      Misc.fatal_errorf "Unbound continuation %a.\n@ \n%a\n%!"
        Continuation.print cont
        print t
    | ty -> ty

  let mem_continuation t cont =
    Continuation.Map.mem cont t.continuations

  let does_not_bind t vars =
    not (List.exists (fun var -> mem t var) vars)

  let does_not_freshen t vars =
    Freshening.does_not_freshen t.freshening vars

  let add_symbol t symbol ty =
    match find_symbol_exn t symbol with
    | exception Not_found ->
      { t with
        symbols = Symbol.Map.add symbol ty t.symbols;
      }
    | _ ->
      Misc.fatal_errorf "Attempt to redefine symbol %a (to %a) in environment \
          for [Simplify]"
        Symbol.print symbol
        Flambda_type.print ty

  let redefine_symbol t symbol ty =
    match find_symbol_exn t symbol with
    | exception Not_found ->
      Misc.fatal_errorf "Cannot redefine undefined symbol %a"
        Symbol.print symbol
    | _ ->
      { t with
        symbols = Symbol.Map.add symbol ty t.symbols;
      }

  let find_exn t id =
    try
      really_import_ty_with_scope t
        (Variable.Map.find id t.variables)
    with Not_found ->
      Misc.fatal_errorf "Env.find_with_scope_exn: Unbound variable \
          %a@.%s@. Environment: %a@."
        Variable.print id
        (Printexc.raw_backtrace_to_string (Printexc.get_callstack max_int))
        print t

  let find_mutable_exn t mut_var =
    try Mutable_variable.Map.find mut_var t.mutable_variables
    with Not_found ->
      Misc.fatal_errorf "Env.find_mutable_exn: Unbound variable \
          %a@.%s@. Environment: %a@."
        Mutable_variable.print mut_var
        (Printexc.raw_backtrace_to_string (Printexc.get_callstack max_int))
        print t

  let find_list_exn t vars =
    List.map (fun var -> find_exn t var) vars

  let variables_in_scope t = Variable.Map.keys t.variables

  let find_opt t id =
    try Some (really_import_ty t
                (snd (Variable.Map.find id t.variables)))
    with Not_found -> None

  let activate_freshening t =
    { t with freshening = Freshening.activate t.freshening }

  (* CR-someday mshinwell: consider changing name to remove "declaration".
     Also, isn't this the inlining stack?  Maybe we can use that instead. *)
  let enter_set_of_closures_declaration t origin =
  (*
  Format.eprintf "Entering decl: have %a, adding %a, result %a\n%!"
  Set_of_closures_origin.Set.print t.current_functions
  Set_of_closures_origin.print origin
  Set_of_closures_origin.Set.print
    (Set_of_closures_origin.Set.add origin t.current_functions);
  *)
    { t with
      current_functions =
        Set_of_closures_origin.Set.add origin t.current_functions; }

  let inside_set_of_closures_declaration origin t =
    Set_of_closures_origin.Set.mem origin t.current_functions

  let at_toplevel t =
    t.closure_depth = 0

  let is_inside_branch env = env.inside_branch > 0

  let branch_depth env = env.inside_branch

  let inside_branch t =
    { t with inside_branch = t.inside_branch + 1 }

  let set_freshening t freshening  =
    { t with freshening; }

  let increase_closure_depth t =
    let ty =
      Variable.Map.map (fun (_scope, ty) -> Outer, ty) t.variables
    in
    { t with
      ty;
      closure_depth = t.closure_depth + 1;
    }

  let set_never_inline t =
    if t.never_inline then t
    else { t with never_inline = true }

  let set_never_inline_inside_closures t =
    if t.never_inline_inside_closures then t
    else { t with never_inline_inside_closures = true }

  let unset_never_inline_inside_closures t =
    if t.never_inline_inside_closures then
      { t with never_inline_inside_closures = false }
    else t

  let set_never_inline_outside_closures t =
    if t.never_inline_outside_closures then t
    else { t with never_inline_outside_closures = true }

  let unset_never_inline_outside_closures t =
    if t.never_inline_outside_closures then
      { t with never_inline_outside_closures = false }
    else t

  let inlining_level_up env =
    let max_level =
      Clflags.Int_arg_helper.get ~key:(env.round) !Clflags.inline_max_depth
    in
    if (env.inlining_level + 1) > max_level then begin
      (* CR mshinwell: Is this a helpful error?  Should we just make this
         robust? *)
      Misc.fatal_error "Inlining level increased above maximum"
    end;
    { env with inlining_level = env.inlining_level + 1 }

  let actively_unrolling t origin =
    match Set_of_closures_origin.Map.find origin t.actively_unrolling with
    | count -> Some count
    | exception Not_found -> None

  let start_actively_unrolling t origin i =
    let actively_unrolling =
      Set_of_closures_origin.Map.add origin i t.actively_unrolling
    in
    { t with actively_unrolling }

  let continue_actively_unrolling t origin =
    let unrolling =
      try
        Set_of_closures_origin.Map.find origin t.actively_unrolling
      with Not_found ->
        Misc.fatal_error "Unexpected actively unrolled function";
    in
    let actively_unrolling =
      Set_of_closures_origin.Map.add origin (unrolling - 1) t.actively_unrolling
    in
    { t with actively_unrolling }

  let unrolling_allowed t origin =
    let unroll_count =
      try
        Set_of_closures_origin.Map.find origin t.unroll_counts
      with Not_found ->
        Clflags.Int_arg_helper.get
          ~key:t.round !Clflags.inline_max_unroll
    in
    unroll_count > 0

  let inside_unrolled_function t origin =
    let unroll_count =
      try
        Set_of_closures_origin.Map.find origin t.unroll_counts
      with Not_found ->
        Clflags.Int_arg_helper.get
          ~key:t.round !Clflags.inline_max_unroll
    in
    let unroll_counts =
      Set_of_closures_origin.Map.add
        origin (unroll_count - 1) t.unroll_counts
    in
    { t with unroll_counts }

  let inlining_allowed t id =
    let inlining_count =
      try
        Closure_origin.Map.find id t.inlining_counts
      with Not_found ->
        max 1 (Clflags.Int_arg_helper.get
                 ~key:t.round !Clflags.inline_max_unroll)
    in
    inlining_count > 0

  let inside_inlined_function t id =
    let inlining_count =
      try
        Closure_origin.Map.find id t.inlining_counts
      with Not_found ->
        max 1 (Clflags.Int_arg_helper.get
                 ~key:t.round !Clflags.inline_max_unroll)
    in
    let inlining_counts =
      Closure_origin.Map.add id (inlining_count - 1) t.inlining_counts
    in
    { t with inlining_counts }

  let inlining_level t = t.inlining_level
  let freshening t = t.freshening
  let never_inline t = t.never_inline || t.never_inline_outside_closures

  let disallow_continuation_inlining t =
    { t with allow_continuation_inlining = false; }

  let never_inline_continuations t =
    not t.allow_continuation_inlining

  let disallow_continuation_specialisation t =
    { t with allow_continuation_specialisation = false; }

  let never_specialise_continuations t =
    not t.allow_continuation_specialisation

  (* CR mshinwell: may want to split this out properly *)
  let never_unbox_continuations = never_specialise_continuations

  let note_entering_closure t ~closure_id ~dbg =
    if t.never_inline then t
    else
      { t with
        inlining_stats_closure_stack =
          Inlining_stats.Closure_stack.note_entering_closure
            t.inlining_stats_closure_stack ~closure_id ~dbg;
      }

  let note_entering_call t ~closure_id ~dbg =
    if t.never_inline then t
    else
      { t with
        inlining_stats_closure_stack =
          Inlining_stats.Closure_stack.note_entering_call
            t.inlining_stats_closure_stack ~closure_id ~dbg;
      }

  let note_entering_inlined t =
    if t.never_inline then t
    else
      { t with
        inlining_stats_closure_stack =
          Inlining_stats.Closure_stack.note_entering_inlined
            t.inlining_stats_closure_stack;
      }

  let note_entering_specialised t ~closure_ids =
    if t.never_inline then t
    else
      { t with
        inlining_stats_closure_stack =
          Inlining_stats.Closure_stack.note_entering_specialised
            t.inlining_stats_closure_stack ~closure_ids;
      }

  let enter_closure t ~closure_id ~inline_inside ~dbg ~f =
    let t =
      if inline_inside && not t.never_inline_inside_closures then t
      else set_never_inline t
    in
    let t = unset_never_inline_outside_closures t in
    f (note_entering_closure t ~closure_id ~dbg)

  let record_decision t decision =
    Inlining_stats.record_decision decision
      ~closure_stack:t.inlining_stats_closure_stack

  let set_inline_debuginfo t ~dbg =
    { t with inlined_debuginfo = dbg }

  let add_inlined_debuginfo t ~dbg =
    Debuginfo.concat t.inlined_debuginfo dbg

  let continuations_in_scope t = t.continuations

  let invariant t =
    if !Clflags.flambda_invariant_checks then begin
      (* Make sure that freshening a continuation through the given
         environment doesn't yield a continuation not bound by the
         environment. *)
      let from_freshening =
        Freshening.range_of_continuation_freshening t.freshening
      in
      Continuation.Set.iter (fun cont ->
          match Continuation.Map.find cont t.continuations with
          | exception Not_found ->
            Misc.fatal_errorf "The freshening in this environment maps to \
                continuation %a, but that continuation is unbound:@;%a"
              Continuation.print cont
              print t
          | _ -> ())
        from_freshening
    end
end and Result : sig
  include Simplify_env_and_result_intf.Result with type env = Env.t
end = struct
  type env = Env.t

  type t =
    { (* CR mshinwell: What about combining these next two? *)
      used_continuations : Continuation_uses.t Continuation.Map.t;
      defined_continuations :
        (Continuation_uses.t * Continuation_approx.t * Env.t
            * Flambda.recursive)
          Continuation.Map.t;
      inlining_threshold : Inlining_cost.Threshold.t option;
      benefit : Inlining_cost.Benefit.t;
      num_direct_applications : int;
    }

  let create () =
    { approx = Flambda_type.value_bottom;
      used_continuations = Continuation.Map.empty;
      defined_continuations = Continuation.Map.empty;
      inlining_threshold = None;
      benefit = Inlining_cost.Benefit.zero;
      num_direct_applications = 0;
    }

  let union t1 t2 =
    { approx = Flambda_type.value_bottom;
      used_continuations =
        Continuation.Map.union_merge Continuation_uses.union
          t1.used_continuations t2.used_continuations;
      defined_continuations =
        Continuation.Map.disjoint_union
          t1.defined_continuations t2.defined_continuations;
      inlining_threshold = t1.inlining_threshold;
      benefit = Inlining_cost.Benefit.(+) t1.benefit t2.benefit;
      num_direct_applications =
        t1.num_direct_applications + t2.num_direct_applications;
    }

  let use_continuation t env cont kind =
    let args = Continuation_uses.Use.Kind.args kind in
    if not (List.for_all (fun arg -> Env.mem env arg) args) then begin
      Misc.fatal_errorf "use_continuation %a: argument(s) (%a) not in \
          environment %a"
        Continuation.print cont
        Variable.print_list args
        Env.print env
    end;
  (*
  let k = 6589 in
  if Continuation.to_int cont = k then begin
  Format.eprintf "Adding use of continuation k%d, args %a approxs %a:\n%s\n%!"
    k
    Variable.print_list args
    (Format.pp_print_list Flambda_type.print)
    (Continuation_uses.Use.Kind.args_approxs kind)
    (Printexc.raw_backtrace_to_string (Printexc.get_callstack 20))
  end;
  *)
    let uses =
      match Continuation.Map.find cont t.used_continuations with
      | exception Not_found ->
        Continuation_uses.create ~continuation:cont ~backend:(Env.backend env)
      | uses -> uses
    in
    let uses = Continuation_uses.add_use uses env kind in
  (*
  if Continuation.to_int cont = k then begin
  Format.eprintf "Join of args approxs for k%d: %a\n%!"
    k
    (Format.pp_print_list Flambda_type.print)
    (Continuation_uses.meet_of_args_approxs uses ~num_params:1)
  end;
  *)
    { t with
      used_continuations =
        Continuation.Map.add cont uses t.used_continuations;
    }

  let non_recursive_continuations_used_linearly_in_inlinable_position t =
    let used_linearly =
      Continuation.Map.filter (fun _cont (uses, _approx, _env, recursive) ->
  (*
  Format.eprintf "NRCUL: continuation %a number of uses %d\n%!"
  Continuation.print _cont
  (List.length uses.Continuation_uses.application_points);
  *)
          match (recursive : Flambda.recursive) with
          | Non_recursive ->
            Continuation_uses.linearly_used_in_inlinable_position uses
          | Recursive -> false)
        t.defined_continuations
    in
    Continuation.Map.keys used_linearly

  let forget_continuation_definition t cont =
    { t with
      defined_continuations =
        Continuation.Map.remove cont t.defined_continuations;
    }

  let is_used_continuation t i =
    Continuation.Map.mem i t.used_continuations

  let used_continuations t =
    Continuation.Map.keys t.used_continuations

  let continuation_uses t = t.used_continuations

  let no_continuations_in_scope t =
    Continuation.Map.is_empty t.used_continuations

  let snapshot_continuation_uses t =
    { Continuation_usage_snapshot.
      used_continuations = t.used_continuations;
      defined_continuations = t.defined_continuations;
    }

  let snapshot_and_forget_continuation_uses t =
    let snapshot = snapshot_continuation_uses t in
    let t =
      { t with
        used_continuations = Continuation.Map.empty;
        defined_continuations = Continuation.Map.empty;
      }
    in
    snapshot, t

  let roll_back_continuation_uses t (snapshot : Continuation_usage_snapshot.t) =
    { t with
      used_continuations = snapshot.used_continuations;
      defined_continuations = snapshot.defined_continuations;
    }

  let continuation_unused t cont =
    not (Continuation.Map.mem cont t.used_continuations)

  let continuation_defined t cont =
    Continuation.Map.mem cont t.defined_continuations

  let continuation_args_approxs t i ~num_params =
    match Continuation.Map.find i t.used_continuations with
    | exception Not_found ->
  (*
  Format.eprintf "Continuation %a not in used_continuations, returning bottom\n%!"
  Continuation.print i;
  *)
      let approxs = Array.make num_params (Flambda_type.value_bottom) in
      Array.to_list approxs
    | uses ->
  (*
  let approxs =
  *)
      Continuation_uses.meet_of_args_approxs uses ~num_params
  (*
  in
  Format.eprintf "Continuation %a IS in used_continuations: %a\n%!"
  Continuation.print i
  (Format.pp_print_list Flambda_type.print) approxs;
  approxs
  *)
  let defined_continuation_args_approxs t i ~num_params =
    match Continuation.Map.find i t.defined_continuations with
    | exception Not_found ->
      let approxs = Array.make num_params (Flambda_type.value_bottom) in
      Array.to_list approxs
    | (uses, _approx, _env, _recursive) ->
      Continuation_uses.meet_of_args_approxs uses ~num_params

  let exit_scope_catch t env i =
  (*
    Format.eprintf "exit_scope_catch %a\n%!" Continuation.print i;
  *)
    let t, uses =
      match Continuation.Map.find i t.used_continuations with
      | exception Not_found ->
  (*
  Format.eprintf "no uses\n%!";
  *)
        let uses =
          Continuation_uses.create ~continuation:i ~backend:(Env.backend env)
        in
        t, uses
      | uses ->
  (*
  let application_points =
  Continuation_uses.application_points uses
  in
  Format.eprintf "Uses:\n";
  let count = ref 1 in
  List.iter (fun (use : Continuation_uses.Use.t) ->
  let env = use.env in
  Format.eprintf "Use %d: %a@ \n%!"
    (!count) Env.print env;
  incr count)
  application_points;
  *)
        { t with
          used_continuations = Continuation.Map.remove i t.used_continuations;
        }, uses
    in
    assert (continuation_unused t i);
  (*
    Format.eprintf "exit_scope_catch %a finished.\n%!" Continuation.print i;
  let application_points =
  Continuation_uses.application_points uses
  in
  Format.eprintf "Uses being returned:\n";
  let count = ref 1 in
  List.iter (fun (use : Continuation_uses.Use.t) ->
  let env = use.env in
  Format.eprintf "Use %d: %a@ \n%!"
    (!count) Env.print env;
  incr count)
  application_points;
  *)
    t, uses

  let update_all_continuation_use_environments t ~if_present_in_env
        ~then_add_to_env =
    let used_continuations =
      Continuation.Map.map (fun uses ->
            Continuation_uses.update_use_environments uses
              ~if_present_in_env ~then_add_to_env)
        t.used_continuations
    in
    let defined_continuations =
      Continuation.Map.map (fun (uses, approx, env, recursive) ->
          let uses =
            Continuation_uses.update_use_environments uses
              ~if_present_in_env ~then_add_to_env
          in
          uses, approx, env, recursive)
        t.defined_continuations
    in
    { t with
      used_continuations;
      defined_continuations;
    }

  let define_continuation t cont env recursive uses approx =
  (*    Format.eprintf "define_continuation %a\n%!" Continuation.print cont;*)
  (*
  let k = 25987 in
  if Continuation.to_int cont = k then begin
  Format.eprintf "Defining continuation k%d:\n%s%!"
    k
    (Printexc.raw_backtrace_to_string (Printexc.get_callstack 30))
  end;
  *)
    Env.invariant env;
    if Continuation.Map.mem cont t.used_continuations then begin
      Misc.fatal_errorf "Must call exit_scope_catch before \
          define_continuation %a"
        Continuation.print cont
    end;
    if Continuation.Map.mem cont t.defined_continuations then begin
      Misc.fatal_errorf "Cannot redefine continuation %a"
        Continuation.print cont
    end;
    { t with
      defined_continuations =
        Continuation.Map.add cont (uses, approx, env, recursive)
          t.defined_continuations;
    }

  let update_defined_continuation_approx t cont approx =
    match Continuation.Map.find cont t.defined_continuations with
    | exception Not_found ->
      Misc.fatal_errorf "Cannot update approximation of undefined \
          continuation %a"
        Continuation.print cont
    | (uses, _old_approx, env, recursive) ->
      { t with
        defined_continuations =
          Continuation.Map.add cont (uses, approx, env, recursive)
            t.defined_continuations;
      }

  let continuation_definitions_with_uses t =
    t.defined_continuations

  let map_benefit t f =
    { t with benefit = f t.benefit }

  let add_benefit t b =
    { t with benefit = Inlining_cost.Benefit.(+) t.benefit b }

  let benefit t = t.benefit

  let reset_benefit t =
    { t with benefit = Inlining_cost.Benefit.zero; }

  let set_inlining_threshold t inlining_threshold =
    { t with inlining_threshold }

  let add_inlining_threshold t j =
    match t.inlining_threshold with
    | None -> t
    | Some i ->
      let inlining_threshold = Some (Inlining_cost.Threshold.add i j) in
      { t with inlining_threshold }

  let sub_inlining_threshold t j =
    match t.inlining_threshold with
    | None -> t
    | Some i ->
      let inlining_threshold = Some (Inlining_cost.Threshold.sub i j) in
      { t with inlining_threshold }

  let inlining_threshold t = t.inlining_threshold

  let seen_direct_application t =
    { t with num_direct_applications = t.num_direct_applications + 1; }

  let num_direct_applications t =
    t.num_direct_applications
end