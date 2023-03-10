(**************************************************************************)
(*                                                                        *)
(*    Copyright 2020 OCamlPro & Origin Labs                               *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

open EzCompat
open Types
open Ez_file.V1
open EzFile.OP

let default_flags =
  { flag_file = "";
    flag_create = false;
    flag_record = true;
    flag_skips = [];
    flag_skip = false;
    flag_skipper = ref [];
    flag_subst = true;
    flag_perm = 0
  }

let bracket flags eval_cond =
  let bracket flags state s =
    match EzString.split s ':' with
    (* set the name of the file *)
    | [ "file"; v ] ->
      flags.flag_file <- v;
      ""
    (* create only once *)
    | [ "create" ] ->
      flags.flag_create <- true;
      ""
    (* skip with this tag *)
    | [ "skip"; v ] ->
      flags.flag_skips <- v :: flags.flag_skips;
      ""
    (* skip always *)
    | [ "skip" ] ->
      flags.flag_skip <- true;
      ""
    (* do not record in .git *)
    | [ "no-record" ] ->
      flags.flag_record <- false;
      ""
    | [ "perm"; v ] ->
      flags.flag_perm <- int_of_string ("0o" ^ v);
      ""
    | "if" :: cond ->
      flags.flag_skipper := not (eval_cond state.Subst.p cond) :: !(flags.flag_skipper);
      ""
    | [ "else" ] ->
      (flags.flag_skipper :=
         match !(flags.flag_skipper) with
         | cond :: tail -> not cond :: tail
         | [] -> failwith "else without if" );
      ""
    | "elif" :: cond ->
      (flags.flag_skipper :=
         match !(flags.flag_skipper) with
         | _cond :: tail -> not (eval_cond state.Subst.p cond) :: tail
         | [] -> failwith "elif without if" );
      ""
    | [ ("fi" | "endif") ] ->
      (flags.flag_skipper :=
         match !(flags.flag_skipper) with
         | _ :: tail -> tail
         | [] -> failwith "fi without if" );
      ""
    | _ ->
      Printf.eprintf "Warning: unknown flag %S\n%!" s;
      ""
  in
  bracket flags

let flags_encoding =
  EzToml.encoding
    ~to_toml:(fun _ -> assert false)
    ~of_toml:(fun ~key v ->
      let table = EzToml.expect_table ~key ~name:"flags" v in
      let flags = { default_flags with flag_file = "" } in
      EzToml.iter
        (fun k v ->
          let key = key @ [ k ] in
          match k with
          | "file" -> flags.flag_file <- EzToml.expect_string ~key v
          | "create" -> flags.flag_create <- EzToml.expect_bool ~key v
          | "record" -> flags.flag_record <- EzToml.expect_bool ~key v
          | "skips" -> flags.flag_skips <- EzToml.expect_string_list ~key v
          | "skip" -> flags.flag_skip <- EzToml.expect_bool ~key v
          | "subst" -> flags.flag_subst <- EzToml.expect_bool ~key v
          | "perm" ->
            flags.flag_perm <- int_of_string ("0o" ^ EzToml.expect_string ~key v)
          | _ ->
            Printf.eprintf "Warning: discarding flags field %S\n%!"
              (EzToml.key2str key) )
        table;
      flags )

let load_skeleton ~version ~drom ~dir ~toml ~kind =
  let table =
    match EzToml.from_file toml with
    | `Ok table -> table
    | `Error _ -> Error.raise "Could not parse skeleton file %S" toml
  in

  let name =
    try EzToml.get_string table [ "skeleton"; "name" ] with
    | Not_found -> failwith "load_skeleton: wrong or missing key skeleton.name"
  in
  let skeleton_inherits =
    EzToml.get_string_option table [ "skeleton"; "inherits" ]
  in
  let skeleton_toml =
    let basename =
      if kind = "project" then
        "drom.toml"
      else if kind = "package" then
        "package.toml"
      else
        assert false
    in
    let file = dir // basename in
    if Sys.file_exists file then
      [ EzFile.read_file file ]
    else begin
      Printf.eprintf "Warning: file %s does not exist\n%!" file;
      []
    end
  in
  let skeleton_files =
    let files = ref [] in
    EzFile.make_select EzFile.iter_dir ~deep:true dir ~kinds:[ S_REG; S_LNK ]
      ~f:(fun path ->
        match String.lowercase (Filename.basename path) with
        | "drom.toml"
        | "package.toml"
        | "skeleton.toml" ->
          ()
        | _ ->
          if not (Filename.check_suffix path "~") then
            let filename = dir // path in
            let content = EzFile.read_file filename in
            let st = Unix.lstat filename in
            let perm = st.Unix.st_perm in
            files := (path, content, perm) :: !files );
    !files
  in
  let skeleton_flags =
    EzToml.get_encoding_default
      (EzToml.ENCODING.stringMap flags_encoding)
      table [ "file" ] StringMap.empty
  in
  begin
    match EzToml.get table [ "files" ] with
    | exception Not_found -> ()
    | _ ->
      Printf.eprintf
        "Warning: %s skeleton %S has an entry [files], probably instead of \
         [file]\n\
         %!"
        kind name
  end;
  (*  Printf.eprintf "Loaded %s skeleton %s\n%!" kind name; *)
  ( name,
    { skeleton_toml;
      skeleton_inherits;
      skeleton_files;
      skeleton_flags;
      skeleton_drom = drom;
      skeleton_name = name;
      skeleton_version =  version;
    } )

let load_dir_skeletons ~version ~drom kind dir =
  let map = ref StringMap.empty in
  if Sys.file_exists dir then begin
    EzFile.iter_dir dir ~f:(fun file ->
        let dir = dir // file in
        let toml = dir // "skeleton.toml" in
        if Sys.file_exists toml then
          try
            let name, skeleton = load_skeleton ~version ~drom ~dir ~toml ~kind in
            if !Globals.verbosity > 0 && StringMap.mem name !map then
              Printf.eprintf "Warning: %s skeleton %S overwritten in %s\n%!"
                kind name dir;
            map := StringMap.add name skeleton !map
          with
          | exn ->
            Printf.eprintf
              "Warning: could not load %s skeleton from %S, exception:\n%S\n%!"
              kind dir (Printexc.to_string exn) );
    !map
  end else
    !map

let kind_dir ~kind = ("skeletons" // kind) ^ "s"

(* TODO: the project should be able to specify its own URL for the skeleton repo *)
let load_skeletons share kind =
  let dir = share.share_dir in
  let version = share.share_version in
  let global_skeletons_dir = dir // kind_dir ~kind in
  load_dir_skeletons ~version ~drom:true kind global_skeletons_dir


let rec inherit_files self_files super_files =
  match (self_files, super_files) with
  | _, [] -> self_files
  | [], _ -> super_files
  | ( (self_file, self_content, self_mode) :: self_files_tail,
      (super_file, super_content, super_mode) :: super_files_tail ) ->
    if self_file = super_file then
      (self_file, self_content, self_mode)
      :: inherit_files self_files_tail super_files_tail
    else if self_file < super_file then
      (self_file, self_content, self_mode)
      :: inherit_files self_files_tail super_files
    else
      (super_file, super_content, super_mode)
      :: inherit_files self_files super_files_tail

let lookup_skeleton skeletons name =
  let rec iter name =
    match StringMap.find name skeletons with
    | exception Not_found ->
        Error.raise "Missing skeleton %S" name
    | self -> (
        match self.skeleton_inherits with
        | None -> self
        | Some super ->
            let super = iter super in
            let skeleton_toml =
              [ String.concat "\n" (super.skeleton_toml @ self.skeleton_toml) ]
            in
            let skeleton_files =
              inherit_files self.skeleton_files super.skeleton_files
            in
            let skeleton_flags =
              StringMap.union
                (fun _ x _ -> Some x)
                self.skeleton_flags super.skeleton_flags
            in
            { skeleton_name = name;
              skeleton_inherits = None;
              skeleton_toml;
              skeleton_files;
              skeleton_drom = false;
              skeleton_flags;
              skeleton_version = self.skeleton_version;
            } )

  (* This should be deprecated in favor of using a skeleton database
     and download_skeleton name =
     if project then (
      match EzString.chop_prefix name ~prefix:"gh:" with
      | None -> Error.raise "Missing skeleton %S" name
      | Some github_project ->
        let url =
          Printf.sprintf "https://github.com/%s/tarball/master" github_project
        in
        let output = Filename.temp_file "archive" ".tgz" in
        Misc.wget ~url ~output;
        let basedir =
          Printf.sprintf "gh-%s" (Digest.string name |> Digest.to_hex)
        in
        let dir = Globals.config_dir // "skeletons" // "projects" // basedir in
        EzFile.make_dir ~p:true dir;
        Misc.call [| "tar"; "zxf"; output; "--strip-components=1"; "-C"; dir |];
        let toml = dir // "skeleton.toml" in
        if not (Sys.file_exists toml) then
          EzFile.write_file toml
            (Printf.sprintf {|[skeleton]
     name = "%s"
     |} name );
        let version = Config.share_version dir in
        let skel_name, skeleton =
          load_skeleton ~version ~drom:false ~dir ~toml ~kind:"project"
        in
        if skel_name = name then
          skeleton
        else
          Error.raise "Wrong remote skeleton %S instead of %S in %s\n" skel_name
            name dir
     ) else
      Error.raise "Missing skeleton %S" name
  *)
  in
  iter name

let backup_skeleton file content ~perm =
  let skeleton_dir = Globals.drom_dir // "skeleton" in
  let drom_file = skeleton_dir // file in
  EzFile.make_dir ~p:true (Filename.dirname drom_file);
  EzFile.write_file drom_file content;
  Unix.chmod drom_file perm

let project_skeletons share =
  match share.share_projects with
  | Some skeletons -> skeletons
  | None ->
      let skeletons = load_skeletons share "project" in
      share.share_projects <- Some skeletons ;
      skeletons

let package_skeletons share =
  match share.share_packages with
  | Some skeletons -> skeletons
  | None ->
      let skeletons = load_skeletons share "package" in
      share.share_packages <- Some skeletons ;
      skeletons

let lookup_project share skeleton =
  let project_skeletons = project_skeletons share in
  lookup_skeleton project_skeletons skeleton

let lookup_package share skeleton =
  let package_skeletons = package_skeletons share in
  lookup_skeleton package_skeletons skeleton

let rec eval_project_cond p cond =
  match cond with
  | [ "skeleton"; "is"; skeleton ] ->
    Misc.project_skeleton p.skeleton = skeleton
  | [ "skip"; skip ] -> List.mem skip p.skip
  | [ "gen"; skip ] -> not (List.mem skip p.skip)
  | "not" :: cond -> not (eval_project_cond p cond)
  | [ "true" ] -> true
  | [ "false" ] -> false
  | [ "ci"; system ] -> List.mem system p.ci_systems
  | [ "github-organization" ] -> p.github_organization <> None
  | [ "homepage" ] -> Misc.homepage p <> None
  | [ "copyright" ] -> p.copyright <> None
  | [ "bug-reports" ] -> Misc.bug_reports p <> None
  | [ "dev-repo" ] -> Misc.dev_repo p <> None
  | [ "doc-gen" ] -> Misc.doc_gen p <> None
  | [ "doc-api" ] -> Misc.doc_api p <> None
  | [ "sphinx-target" ] -> p.sphinx_target <> None
  | [ "profile" ] -> p.profile <> None
  | [ "min-edition" ] -> p.min_edition <> p.edition
  | [ "field"; name ] -> StringMap.mem name p.fields
  | "field" :: name :: v ->
    let v = String.concat ":" v in
    begin
      match StringMap.find name p.fields with
      | exception Not_found -> false
      | x -> x = v
    end
  | _ ->
    Printf.kprintf failwith "eval_project_cond: unknown condition %S\n%!"
      (String.concat ":" cond)

let rec eval_package_cond p cond =
  match cond with
  | [ "skeleton"; "is"; skeleton ] -> Misc.package_skeleton p = skeleton
  | [ "kind"; "is"; kind ] -> kind = Misc.string_of_kind p.kind
  | [ "pack" ] -> Misc.p_pack_modules p
  | [ "skip"; skip ] -> List.mem skip p.project.skip
  | [ "gen"; skip ] -> not (List.mem skip p.project.skip)
  | "not" :: cond -> not (eval_package_cond p cond)
  | [ "true" ] -> true
  | [ "false" ] -> false
  | "project" :: cond -> eval_project_cond p.project cond
  | [ "field"; name ] -> StringMap.mem name p.p_fields
  | "field" :: name :: v ->
    let v = String.concat ":" v in
    begin
      match StringMap.find name p.p_fields with
      | exception Not_found -> false
      | x -> x = v
    end
  | _ ->
    Printf.kprintf failwith "eval_package_cond: unknown condition %S\n%!"
      (String.concat ":" cond)

let default_flags flag_file =
  { default_flags with flag_file; flag_skipper = ref [] }

let skeleton_flags skeleton file =
  try
    let flags =
      try StringMap.find file skeleton.skeleton_flags with
      (* This is absurd: toml.5.0.0 does not treat quoted keys and
         unquoted keys internally in the same way... *)
      | Not_found -> (
        try
          StringMap.find (Printf.sprintf "\"%s\"" file) skeleton.skeleton_flags
        with
        | Not_found ->
          if Globals.verbose 2 then
            Printf.eprintf "skeleton %S has no flags for file %S\n%!"
              skeleton.skeleton_name file;
          raise Not_found )
    in
    if flags.flag_file = "" then
      { flags with flag_file = file; flag_skipper = ref [] }
    else
      { flags with flag_skipper = ref [] }
  with
  | Not_found -> default_flags file

let skeleton_flags skeleton file perm =
  let flags = skeleton_flags skeleton file in
  if flags.flag_perm = 0 then flags.flag_perm <- perm;
  if Filename.check_suffix file ".sh" then
    flags.flag_perm <- flags.flag_perm lor 0o111;
  flags

let write_project_files write_file state =
  let p = state.Subst.p in
  let skeleton = lookup_project state.share (Misc.project_skeleton p.skeleton) in
  let postponed_items = ref [] in

  let write_project_file ~postpone (file, content, perm) =
    (* Printf.eprintf "File %s perm %o\n%!" file perm; *)
    backup_skeleton file content ~perm;
    let flags = skeleton_flags skeleton file perm in
    let bracket = bracket flags eval_project_cond in
    let content =
      if flags.flag_subst then
        try
          Subst.project { state with postpone }
            ~bracket ~skipper:flags.flag_skipper content
        with
        | Not_found ->
            Printf.kprintf failwith "Exception Not_found in %S\n%!" file
      else
        content
    in
    (* name of file can also be substituted *)
    let { flag_file;
          flag_create = create;
          flag_skips = skips;
          flag_record = record;
          flag_skip = skip;
          flag_perm = perm;
          flag_skipper = _;
          flag_subst = _
        } =
      flags
    in
    let flag_file = Subst.project state flag_file in
    write_file flag_file ~create ~skips ~content ~record ~skip ~perm
  in
  List.iter
    (fun file_item ->
       try
         write_project_file ~postpone:true file_item
       with Subst.Postpone ->
         postponed_items := file_item :: !postponed_items
    )
    skeleton.skeleton_files;
  List.iter
    (fun file_item ->
       write_project_file ~postpone:false file_item
    )
    skeleton.skeleton_files;
  ()

let subst_package_file flags content state =
  let bracket = bracket flags eval_package_cond in
  let content =
    if flags.flag_subst then
      try
        Subst.package state
          ~bracket ~skipper:flags.flag_skipper content
      with
      | Not_found ->
        Printf.kprintf failwith "Exception Not_found in %S\n%!" flags.flag_file
    else
      content
  in
  content

let write_package_files write_file state =
  let package = state.Subst.p in
  let skeleton = lookup_package state.share (Misc.package_skeleton package) in
  List.iter
    (fun (file, content, perm) ->
      (* Printf.eprintf "File %s perm %o\n%!" file perm; *)
      backup_skeleton file content ~perm;
      let flags = skeleton_flags skeleton file perm in
      let content = subst_package_file flags content state in
      let { flag_file;
            flag_create = create;
            flag_skips = skips;
            flag_record = record;
            flag_skip = skip;
            flag_perm = perm;
            flag_skipper = _;
            flag_subst = _
          } =
        flags
      in
      let flag_file = Subst.package state flag_file in
      let file = package.dir // flag_file in
      write_file file ~create ~skips ~content ~record ~skip ~perm )
    skeleton.skeleton_files

let write_files write_file state =
  write_project_files write_file state;
  List.iter (fun package ->
      write_package_files write_file { state with p = package })
    state.Subst.p.packages

let project_skeletons share =
  project_skeletons share
  |> StringMap.to_list |> List.map snd

let package_skeletons share =
  package_skeletons share
  |> StringMap.to_list |> List.map snd

let known_skeletons share =
  Printf.sprintf "project skeletons: %s\npackage skeletons: %s\n"
    ( project_skeletons share
    |> List.map (fun s -> s.skeleton_name)
    |> String.concat " " )
    ( package_skeletons share
    |> List.map (fun s -> s.skeleton_name)
    |> String.concat " " )

let to_string s =
  Printf.sprintf
    {|
  { skeleton_inherits = %s ;
    skeleton_toml : [ %d entries ] ;
    skeleton_files : [ %d entries ] ;
    skeleton_flags : { %d entries };
    skeleton_drom = %b ;
    skeleton_name = %S ;
  }
|}
    ( match s.skeleton_inherits with
    | None -> ""
    | Some s -> Printf.sprintf "%S" s )
    (List.length s.skeleton_toml)
    (List.length s.skeleton_files)
    (StringMap.cardinal s.skeleton_flags)
    s.skeleton_drom s.skeleton_name
