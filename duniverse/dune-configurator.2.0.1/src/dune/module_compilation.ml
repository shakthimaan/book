open! Stdune
open Import
open! No_io
module CC = Compilation_context
module SC = Super_context

(* Arguments for the compiler to prevent it from being too clever.

   The compiler creates the cmi when it thinks a .ml file has no corresponding
   .mli. However this behavior is a bit racy and doesn't work well when the
   extension is not .ml or when the .ml and .mli are in different directories.
   This flags makes the compiler think there is a .mli file and will the read
   the cmi file rather than create it. *)
let force_read_cmi source_file = [ "-intf-suffix"; Path.extension source_file ]

(* Build the cm* if the corresponding source is present, in the case of cmi if
   the mli is not present it is added as additional target to the .cmo
   generation *)

let opens modules m =
  match Modules.alias_for modules m with
  | None -> Command.Args.empty
  | Some (m : Module.t) -> As [ "-open"; Module_name.to_string (Module.name m) ]

let other_cm_files ~opaque ~(cm_kind : Cm_kind.t) ~dep_graph ~obj_dir m =
  let open Build.O in
  let+ deps = Dep_graph.deps_of dep_graph m in
  List.concat_map deps ~f:(fun m ->
      let deps =
        [ Path.build (Obj_dir.Module.cm_file_unsafe obj_dir m ~kind:Cmi) ]
      in
      if Module.has m ~ml_kind:Impl && cm_kind = Cmx && not opaque then
        let cmx = Obj_dir.Module.cm_file_unsafe obj_dir m ~kind:Cmx in
        Path.build cmx :: deps
      else
        deps)

let copy_interface ~sctx ~dir ~obj_dir m =
  (* symlink the .cmi into the public interface directory *)
  if
    Module.visibility m <> Visibility.Private
    && Obj_dir.need_dedicated_public_dir obj_dir
  then
    SC.add_rule sctx ~dir
      (Build.symlink
         ~src:(Path.build (Obj_dir.Module.cm_file_unsafe obj_dir m ~kind:Cmi))
         ~dst:(Obj_dir.Module.cm_public_file_unsafe obj_dir m ~kind:Cmi))

let build_cm cctx ~dep_graphs ~precompiled_cmi ~cm_kind (m : Module.t) ~phase =
  let sctx = CC.super_context cctx in
  let dir = CC.dir cctx in
  let obj_dir = CC.obj_dir cctx in
  let ctx = SC.context sctx in
  let stdlib = CC.stdlib cctx in
  let mode = Mode.of_cm_kind cm_kind in
  let dynlink = CC.dynlink cctx in
  let sandbox = CC.sandbox cctx in
  (let open Option.O in
  let* compiler = Context.compiler ctx mode in
  let ml_kind = Cm_kind.source cm_kind in
  let+ src = Module.file m ~ml_kind in
  let dst = Obj_dir.Module.cm_file_unsafe obj_dir m ~kind:cm_kind in
  let obj =
    Obj_dir.Module.obj_file obj_dir m ~kind:Cmx ~ext:ctx.lib_config.ext_obj
  in
  let linear =
    Obj_dir.Module.obj_file obj_dir m ~kind:Cmx ~ext:Fdo.linear_ext
  in
  let linear_fdo =
    Obj_dir.Module.obj_file obj_dir m ~kind:Cmx ~ext:Fdo.linear_fdo_ext
  in
  let extra_args, extra_deps, other_targets =
    if precompiled_cmi then
      (force_read_cmi src, [], [])
    else
      (* If we're compiling an implementation, then the cmi is present *)
      let public_vlib_module = Module.kind m = Impl_vmodule in
      match phase with
      | Some Fdo.Emit -> ([], [], [])
      | Some Fdo.Compile
      | Some Fdo.All
      | None -> (
        match (cm_kind, Module.file m ~ml_kind:Intf, public_vlib_module) with
        (* If there is no mli, [ocamlY -c file.ml] produces both the .cmY and
           .cmi. We choose to use ocamlc to produce the cmi and to produce the
           cmx we have to wait to avoid race conditions. *)
        | Cmo, None, false ->
          copy_interface ~dir ~obj_dir ~sctx m;
          ([], [], [ Obj_dir.Module.cm_file_unsafe obj_dir m ~kind:Cmi ])
        | Cmo, None, true
        | (Cmo | Cmx), _, _ ->
          ( force_read_cmi src
          , [ Path.build (Obj_dir.Module.cm_file_unsafe obj_dir m ~kind:Cmi) ]
          , [] )
        | Cmi, _, _ ->
          copy_interface ~dir ~obj_dir ~sctx m;
          ([], [], []) )
  in
  let other_targets =
    match cm_kind with
    | Cmx -> (
      match phase with
      | Some Fdo.Compile -> linear :: other_targets
      | Some Fdo.Emit -> other_targets
      | Some Fdo.All
      | None ->
        obj :: other_targets )
    | Cmi
    | Cmo ->
      other_targets
  in
  let dep_graph = Ml_kind.Dict.get dep_graphs ml_kind in
  let opaque = CC.opaque cctx in
  let other_cm_files =
    Build.dyn_paths_unit
      (other_cm_files ~opaque ~cm_kind ~dep_graph ~obj_dir m)
  in
  let other_targets, cmt_args =
    match cm_kind with
    | Cmx -> (other_targets, Command.Args.empty)
    | Cmi
    | Cmo ->
      let fn = Option.value_exn (Obj_dir.Module.cmt_file obj_dir m ~ml_kind) in
      (fn :: other_targets, A "-bin-annot")
  in
  let opaque_arg =
    let intf_only = cm_kind = Cmi && not (Module.has m ~ml_kind:Impl) in
    if
      opaque || (intf_only && Ocaml_version.supports_opaque_for_mli ctx.version)
    then
      Command.Args.A "-opaque"
    else
      Command.Args.empty
  in
  let dir = ctx.build_dir in
  let flags =
    let flags = Ocaml_flags.get (CC.flags cctx) mode in
    match Module.pp_flags m with
    | None -> flags
    | Some pp ->
      let open Build.O in
      let+ flags = flags
      and+ pp_flags = pp in
      flags @ pp_flags
  in
  let output =
    match phase with
    | Some Fdo.Compile -> dst
    | Some Fdo.Emit -> obj
    | Some Fdo.All
    | None ->
      dst
  in
  let src =
    match phase with
    | Some Fdo.Emit -> Path.build linear_fdo
    | Some Fdo.Compile
    | Some Fdo.All
    | None ->
      src
  in
  let modules = Compilation_context.modules cctx in
  SC.add_rule sctx ~sandbox ~dir
    (let open Build.O in
    Build.paths extra_deps >>> other_cm_files
    >>> Command.run ~dir:(Path.build dir) (Ok compiler)
          [ Command.Args.dyn flags
          ; cmt_args
          ; Command.Args.S
              ( Obj_dir.all_obj_dirs obj_dir ~mode
              |> List.concat_map ~f:(fun p ->
                     [ Command.Args.A "-I"; Path (Path.build p) ]) )
          ; Cm_kind.Dict.get (CC.includes cctx) cm_kind
          ; As extra_args
          ; ( if dynlink || cm_kind <> Cmx then
              Command.Args.empty
            else
              A "-nodynlink" )
          ; A "-no-alias-deps"
          ; opaque_arg
          ; As (Fdo.phase_flags phase)
          ; opens modules m
          ; As
              ( match stdlib with
              | None -> []
              | Some _ ->
                (* XXX why aren't these just normal library flags? *)
                [ "-nopervasives"; "-nostdlib" ] )
          ; A "-o"
          ; Target output
          ; A "-c"
          ; Command.Ml_kind.flag ml_kind
          ; Dep src
          ; Hidden_targets other_targets
          ]))
  |> Option.value ~default:()

let build_module ~dep_graphs ?(precompiled_cmi = false) cctx m =
  build_cm cctx m ~dep_graphs ~precompiled_cmi ~cm_kind:Cmo ~phase:None;
  let ctx = CC.context cctx in
  let can_split =
    Ocaml_version.supports_split_at_emit ctx.version
    || Ocaml_config.is_dev_version ctx.ocaml_config
  in
  ( match (ctx.fdo_target_exe, can_split) with
  | None, _ ->
    build_cm cctx m ~dep_graphs ~precompiled_cmi ~cm_kind:Cmx ~phase:None
  | Some _, false ->
    build_cm cctx m ~dep_graphs ~precompiled_cmi ~cm_kind:Cmx
      ~phase:(Some Fdo.All)
  | Some _, true ->
    build_cm cctx m ~dep_graphs ~precompiled_cmi ~cm_kind:Cmx
      ~phase:(Some Fdo.Compile);
    Fdo.opt_rule cctx m;
    build_cm cctx m ~dep_graphs ~precompiled_cmi ~cm_kind:Cmx
      ~phase:(Some Fdo.Emit) );
  if not precompiled_cmi then
    build_cm cctx m ~dep_graphs ~precompiled_cmi ~cm_kind:Cmi ~phase:None;
  Compilation_context.js_of_ocaml cctx
  |> Option.iter ~f:(fun js_of_ocaml ->
         (* Build *.cmo.js *)
         let sctx = CC.super_context cctx in
         let dir = CC.dir cctx in
         let obj_dir = CC.obj_dir cctx in
         let src = Obj_dir.Module.cm_file_unsafe obj_dir m ~kind:Cm_kind.Cmo in
         let target = Path.Build.extend_basename src ~suffix:".js" in
         SC.add_rules sctx ~dir
           (Js_of_ocaml_rules.build_cm cctx ~js_of_ocaml ~src ~target))

let ocamlc_i ?(flags = []) ~dep_graphs cctx (m : Module.t) ~output =
  let sctx = CC.super_context cctx in
  let obj_dir = CC.obj_dir cctx in
  let dir = CC.dir cctx in
  let ctx = SC.context sctx in
  let src = Option.value_exn (Module.file m ~ml_kind:Impl) in
  let dep_graph = Ml_kind.Dict.get dep_graphs Impl in
  let sandbox = Compilation_context.sandbox cctx in
  let cm_deps =
    Build.dyn_paths_unit
      (let open Build.O in
      let+ deps = Dep_graph.deps_of dep_graph m in
      List.concat_map deps ~f:(fun m ->
          [ Path.build (Obj_dir.Module.cm_file_unsafe obj_dir m ~kind:Cmi) ]))
  in
  let ocaml_flags = Ocaml_flags.get (CC.flags cctx) Mode.Byte in
  let modules = Compilation_context.modules cctx in
  SC.add_rule sctx ~sandbox ~dir
    (Build.action_dyn ~targets:[ output ]
       (let open Build.O in
       cm_deps
       >>> Build.map
             ~f:(Action.with_stdout_to output)
             (Command.run (Ok ctx.ocamlc) ~dir:(Path.build ctx.build_dir)
                [ Command.Args.dyn ocaml_flags
                ; A "-I"
                ; Path (Path.build (Obj_dir.byte_dir obj_dir))
                ; Cm_kind.Dict.get (CC.includes cctx) Cmo
                ; opens modules m
                ; As flags
                ; A "-short-paths"
                ; A "-i"
                ; Command.Ml_kind.flag Impl
                ; Dep src
                ])))

(* The alias module is an implementation detail to support wrapping library
   modules under a single toplevel name. Since OCaml doesn't have proper
   support for namespacing at the moment, in order to expose module `X` of
   library `foo` as `Foo.X`, Dune does the following:

   - it compiles x.ml to Foo__X.cmo, Foo__X.cmx, Foo__X.o, ... - it implictly
   exposes a module alias [module X = Foo__X] to all the modules of the `foo`
   library

   The second point is achieved by implicitely openning a module containing
   such aliases for all modules of `foo` when compiling modules of `foo` via
   the `-open` option of the compiler. This module is called the alias module
   and is implicitely generated by Dune.*)

let build_alias_module ~loc ~alias_module ~dir ~cctx =
  let sctx = Compilation_context.super_context cctx in
  let file = Option.value_exn (Module.file alias_module ~ml_kind:Impl) in
  let modules = Compilation_context.modules cctx in
  let alias_file () =
    let main_module_name =
      Modules.main_module_name modules |> Option.value_exn
    in
    Modules.for_alias modules |> Module_name.Map.values
    |> List.map ~f:(fun (m : Module.t) ->
           let name = Module_name.to_string (Module.name m) in
           sprintf "(** @canonical %s.%s *)\nmodule %s = %s\n"
             (Module_name.to_string main_module_name)
             name name
             (Module_name.to_string (Module.real_unit_name m)))
    |> String.concat ~sep:"\n"
  in
  Super_context.add_rule ~loc sctx ~dir
    ( Build.delayed alias_file
    |> Build.write_file_dyn (Path.as_in_build_dir_exn file) );
  let cctx = Compilation_context.for_alias_module cctx in
  build_module cctx alias_module
    ~dep_graphs:(Dep_graph.Ml_kind.dummy alias_module)

let build_all cctx ~dep_graphs =
  let for_wrapped_compat =
    lazy (Compilation_context.for_wrapped_compat cctx)
  in
  let modules = Compilation_context.modules cctx in
  Modules.iter_no_vlib modules ~f:(fun m ->
      match Module.kind m with
      | Alias ->
        let cctx = Compilation_context.for_alias_module cctx in
        let dir = Compilation_context.dir cctx in
        build_alias_module ~loc:Loc.none ~alias_module:m ~dir ~cctx
      | Wrapped_compat ->
        let cctx = Lazy.force for_wrapped_compat in
        build_module cctx ~dep_graphs m
      | _ ->
        let cctx =
          if Modules.is_stdlib_alias modules m then
            (* XXX it would probably be simpler if the flags were just for this
               module in the definition of the stanza *)
            Compilation_context.for_alias_module cctx
          else
            cctx
        in
        build_module cctx ~dep_graphs m)
