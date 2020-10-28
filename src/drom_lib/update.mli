(**************************************************************************)
(*                                                                        *)
(*    Copyright 2020 OCamlPro & Origin Labs                               *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

type update_args = {
  mutable arg_upgrade : bool ;
  mutable arg_force : bool ;
  mutable arg_diff : bool ;
  mutable arg_skip : ( bool * string ) list ;
}

val update_args : unit ->
  update_args * (string list * Ezcmd.TYPES.Arg.spec * Ezcmd.TYPES.info) list

val update_files :
  ?args:update_args ->
  ?mode:Types.mode ->
  ?git:bool ->
  ?create:bool ->
  ?promote_skip:bool ->
  Types.project ->
  unit

val compute_config_hash : ( string * string ) list -> string
