module Env = Semgrep_envvars
open Lsp
open Types
open Fpath_.Operators
module OutJ = Semgrep_output_v1_t

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

(* We really don't wan't mutable state in the server.
   This is the only exception *)
type session_cache = {
  mutable rules : Rule.t list; [@opaque]
  mutable skipped_app_fingerprints : string list;
  mutable open_documents : Fpath.t list;
  lock : Lwt_mutex.t; [@opaque]
}
[@@deriving show]

type t = {
  capabilities : ServerCapabilities.t;
      [@printer
        fun fmt c ->
          Yojson.Safe.pretty_print fmt (ServerCapabilities.yojson_of_t c)]
  workspace_folders : Fpath.t list;
  cached_workspace_targets : (Fpath.t, Fpath.t list) Hashtbl.t; [@opaque]
  cached_scans : (Fpath.t, OutJ.cli_match list) Hashtbl.t; [@opaque]
  cached_session : session_cache;
  skipped_local_fingerprints : string list;
  user_settings : User_settings.t;
  metrics : LS_metrics.t;
  is_intellij : bool;
}
[@@deriving show]

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let create capabilities =
  let cached_session =
    {
      rules = [];
      skipped_app_fingerprints = [];
      lock = Lwt_mutex.create ();
      open_documents = [];
    }
  in
  {
    capabilities;
    workspace_folders = [];
    cached_workspace_targets = Hashtbl.create 10;
    cached_scans = Hashtbl.create 10;
    cached_session;
    skipped_local_fingerprints = [];
    user_settings = User_settings.default;
    metrics = LS_metrics.default;
    is_intellij = false;
  }

let dirty_files_of_folder folder =
  let git_repo = Git_wrapper.is_git_repo ~cwd:folder () in
  if git_repo then
    let dirty_files = Git_wrapper.dirty_files ~cwd:folder () in
    Some (List_.map (fun x -> folder // x) dirty_files)
  else None

let decode_rules data =
  let caps = Cap.network_caps_UNSAFE () in
  Common2.with_tmp_file ~str:data ~ext:"json" (fun file ->
      let file = Fpath.v file in
      let res =
        Rule_fetching.load_rules_from_file ~rewrite_rule_ids:false ~origin:App
          ~registry_caching:true caps file
      in
      Logs.info (fun m -> m "Loaded %d rules from CI" (List.length res.rules));
      Logs.info (fun m -> m "Got %d errors from CI" (List.length res.errors));
      res)

let get_targets session root =
  let targets_conf =
    User_settings.find_targets_conf_of_t session.user_settings
  in
  Find_targets.get_target_fpaths
    { targets_conf with project_root = Some root }
    [ root ]
  |> fst

(*****************************************************************************)
(* State getters *)
(*****************************************************************************)

let auth_token () =
  match !Semgrep_envvars.v.app_token with
  | Some token -> Some token
  | None ->
      let settings = Semgrep_settings.load () in
      settings.api_token

let cache_workspace_targets session =
  let folders = session.workspace_folders in
  let targets = List_.map (fun f -> (f, get_targets session f)) folders in
  List.iter
    (fun (folder, targets) ->
      Hashtbl.replace session.cached_workspace_targets folder targets)
    targets

(* This is dynamic so if the targets file is updated we don't have to restart
 *)
let targets session =
  let dirty_files =
    List_.map (fun f -> (f, dirty_files_of_folder f)) session.workspace_folders
  in
  let member_folder_dirty_files file folder =
    let dirty_files = List.assoc folder dirty_files in
    match dirty_files with
    | None -> true
    | Some files -> List.mem file files
  in
  let member_workspace_folder file folder =
    Fpath.is_prefix folder file
    && ((not session.user_settings.only_git_dirty)
       || member_folder_dirty_files file folder)
  in
  let member_workspaces t =
    List.exists (fun f -> member_workspace_folder t f) session.workspace_folders
  in
  let workspace_targets f =
    Hashtbl.find_opt session.cached_workspace_targets f
    |> Option.value ~default:[]
  in
  let targets =
    session.workspace_folders |> List.concat_map workspace_targets
  in
  (* Filter targets by if only_git_dirty, if they are a dirty file *)
  targets |> List.filter member_workspaces

let fetch_ci_rules_and_origins () =
  let token = auth_token () in
  match token with
  | Some token ->
      let caps =
        Auth.cap_token_and_network token (Cap.network_caps_UNSAFE ())
      in
      let%lwt res =
        Semgrep_App.fetch_scan_config_async caps ~sca:false ~dry_run:true
          ~full_scan:true ~repository:""
      in
      let conf =
        match res with
        | Ok scan_config -> Some (decode_rules scan_config.rule_config)
        | Error e ->
            Logs.warn (fun m -> m "Failed to fetch rules from CI: %s" e);
            None
      in
      Lwt.return conf
  | _ -> Lwt.return None

let fetch_rules session =
  let%lwt ci_rules =
    if session.user_settings.ci then fetch_ci_rules_and_origins ()
    else Lwt.return_none
  in
  let home = Unix.getenv "HOME" |> Fpath.v in
  let rules_source =
    session.user_settings.configuration |> List_.map Fpath.v
    |> List_.map Fpath.normalize
    |> List_.map (fun f ->
           let p = Fpath.rem_prefix (Fpath.v "~/") f in
           Option.bind p (fun f -> Some (home // f)) |> Option.value ~default:f)
    |> List_.map Fpath.to_string
  in
  let rules_source =
    if rules_source = [] && ci_rules = None then (
      Logs.debug (fun m -> m "No rules source specified, using auto");
      [ "auto" ])
    else rules_source
  in
  let caps = Cap.network_caps_UNSAFE () in
  let%lwt rules_and_origins =
    Lwt_list.map_p
      (fun source ->
        let in_docker = !Semgrep_envvars.v.in_docker in
        let config = Rules_config.parse_config_string ~in_docker source in
        Rule_fetching.rules_from_dashdash_config_async
          ~rewrite_rule_ids:true (* default *)
          ~token_opt:(auth_token ()) ~registry_caching:true caps config)
      rules_source
  in
  let rules_and_origins = List.flatten rules_and_origins in
  let rules_and_origins =
    match ci_rules with
    | Some r ->
        Logs.info (fun m -> m "Got %d rules from CI" (List.length r.rules));
        r :: rules_and_origins
    | None ->
        Logs.info (fun m -> m "No rules from CI");
        rules_and_origins
  in
  let rules, errors =
    Rule_fetching.partition_rules_and_errors rules_and_origins
  in
  let rules =
    List_.uniq_by
      (fun r1 r2 -> Rule_ID.equal (fst r1.Rule.id) (fst r2.Rule.id))
      rules
  in
  let rule_filtering_conf =
    Rule_filtering.
      {
        exclude_rule_ids = [];
        severity = [];
        (* Exclude these as they require the pro engine which we don't support *)
        exclude_products = [ `SCA; `Secrets ];
      }
  in
  let rules, errors =
    (Rule_filtering.filter_rules rule_filtering_conf rules, errors)
  in

  Lwt.return (rules, errors)

let fetch_skipped_app_fingerprints () =
  (* At some point we should allow users to ignore ids locally *)
  let auth_token = auth_token () in
  match auth_token with
  | Some token -> (
      let caps =
        Auth.cap_token_and_network token (Cap.network_caps_UNSAFE ())
      in

      let%lwt deployment_opt =
        Semgrep_App.get_scan_config_from_token_async caps
      in
      match deployment_opt with
      | Some deployment -> Lwt.return deployment.triage_ignored_match_based_ids
      | None -> Lwt.return [])
  | None -> Lwt.return []

(* Useful for when we need to reset diagnostics, such as when changing what
 * rules we've run *)
let scanned_files session =
  (* We can get duplicates apparently *)
  Hashtbl.fold (fun file _ acc -> file :: acc) session.cached_scans []
  |> List.sort_uniq Fpath.compare

let skipped_fingerprints session =
  let skipped_fingerprints =
    session.cached_session.skipped_app_fingerprints
    @ session.skipped_local_fingerprints
  in
  List.sort_uniq String.compare skipped_fingerprints

let runner_conf session =
  User_settings.core_runner_conf_of_t session.user_settings

let previous_scan_of_file session file =
  Hashtbl.find_opt session.cached_scans file

let save_local_skipped_fingerprints session =
  let save_dir =
    !Env.v.user_dot_semgrep_dir / "cache" / "fingerprinted_ignored_findings"
  in
  if not (Sys.file_exists (Fpath.to_string save_dir)) then
    Sys.mkdir (Fpath.to_string save_dir) 0o755;
  let save_file_name =
    String.concat "_" (List_.map Fpath.basename session.workspace_folders)
    ^ ".txt"
  in
  let save_file = save_dir / save_file_name |> Fpath.to_string in
  let skipped_fingerprints = skipped_fingerprints session in
  let skipped_fingerprints = String.concat "\n" skipped_fingerprints in
  UCommon.with_open_outfile save_file (fun (_pr, chan) ->
      output_string chan skipped_fingerprints)

let load_local_skipped_fingerprints session =
  let save_dir = !Env.v.user_dot_semgrep_dir / "cache" / "fingerprints" in
  let save_file_name =
    String.concat "_" (List_.map Fpath.basename session.workspace_folders)
    ^ ".txt"
  in
  let save_file = save_dir / save_file_name |> Fpath.to_string in
  if not (Sys.file_exists save_file) then session
  else
    let skipped_local_fingerprints =
      UCommon.read_file save_file
      |> String.split_on_char '\n'
      |> List.filter (fun s -> s <> "")
    in
    { session with skipped_local_fingerprints }
(*****************************************************************************)
(* State setters *)
(*****************************************************************************)

let cache_session session =
  let%lwt rules, _ = fetch_rules session in
  let%lwt skipped_app_fingerprints = fetch_skipped_app_fingerprints () in
  Lwt_mutex.with_lock session.cached_session.lock (fun () ->
      session.cached_session.rules <- rules;
      session.cached_session.skipped_app_fingerprints <-
        skipped_app_fingerprints;
      Lwt.return_unit)

let add_skipped_fingerprint session fingerprint =
  {
    session with
    skipped_local_fingerprints =
      fingerprint :: session.skipped_local_fingerprints;
  }

let add_open_document session file =
  Lwt.async (fun () ->
      Lwt_mutex.with_lock session.cached_session.lock (fun () ->
          session.cached_session.open_documents <-
            file :: session.cached_session.open_documents;
          Lwt.return_unit))

let remove_open_document session file =
  Lwt.async (fun () ->
      Lwt_mutex.with_lock session.cached_session.lock (fun () ->
          session.cached_session.open_documents <-
            List.filter
              (fun f -> not (Fpath.equal f file))
              session.cached_session.open_documents;
          Lwt.return_unit))

let remove_open_documents session files =
  Lwt.async (fun () ->
      Lwt_mutex.with_lock session.cached_session.lock (fun () ->
          session.cached_session.open_documents <-
            List.filter
              (fun f -> not (List.mem f files))
              session.cached_session.open_documents;
          Lwt.return_unit))

let update_workspace_folders ?(added = []) ?(removed = []) session =
  let workspace_folders =
    session.workspace_folders
    |> List.filter (fun folder -> not (List.mem folder removed))
    |> List.append added
  in
  { session with workspace_folders }

let record_results session results files =
  let results_by_file =
    Assoc.group_by (fun (r : OutJ.cli_match) -> r.path) results
  in
  List.iter (fun f -> Hashtbl.replace session.cached_scans f []) files;
  List.iter
    (fun (f, results) -> Hashtbl.add session.cached_scans f results)
    results_by_file;
  ()
