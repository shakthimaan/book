open Asn.S
open Asn_grammars

(* This type really conflates three things: the set of pk algos that describe
 * the public key, the set of hashes, and the set of hash+pk algo combinations
 * that describe digests. The three are conflated because they are generated by
 * the same ASN grammar, AlgorithmIdentifier, to keep things close to the
 * standards.
 *
 * It's expected that downstream code with pick a subset and add a catch-all
 * that handles unsupported algos anyway.
 *)

type signature  = [ `RSA | `ECDSA ]

type t =

  (* pk algos *)
  (* any more? is the universe big enough? ramsey's theorem for pk cyphers? *)
  | RSA
  | EC_pub of Asn.oid (* should translate the oid too *)

  (* sig algos *)
  | MD2_RSA
  | MD4_RSA
  | MD5_RSA
  | RIPEMD160_RSA
  | SHA1_RSA
  | SHA256_RSA
  | SHA384_RSA
  | SHA512_RSA
  | SHA224_RSA
  | ECDSA_SHA1
  | ECDSA_SHA224
  | ECDSA_SHA256
  | ECDSA_SHA384
  | ECDSA_SHA512

  (* digest algorithms *)
  | MD2
  | MD4
  | MD5
  | SHA1
  | SHA256
  | SHA384
  | SHA512
  | SHA224
  | SHA512_224
  | SHA512_256

let to_hash = function
  | MD5    -> Some `MD5
  | SHA1   -> Some `SHA1
  | SHA224 -> Some `SHA224
  | SHA256 -> Some `SHA256
  | SHA384 -> Some `SHA384
  | SHA512 -> Some `SHA512
  | _      -> None

and of_hash = function
  | `MD5    -> MD5
  | `SHA1   -> SHA1
  | `SHA224 -> SHA224
  | `SHA256 -> SHA256
  | `SHA384 -> SHA384
  | `SHA512 -> SHA512

and to_key_type = function
  | RSA        -> Some `RSA
  | EC_pub oid -> Some (`EC oid)
  | _          -> None

and of_key_type = function
  | `RSA    -> RSA
  | `EC oid -> EC_pub oid

(* XXX: No MD2 / MD4 / RIPEMD160 *)
and to_signature_algorithm = function
  | MD5_RSA       -> Some (`RSA  , `MD5)
  | SHA1_RSA      -> Some (`RSA  , `SHA1)
  | SHA256_RSA    -> Some (`RSA  , `SHA256)
  | SHA384_RSA    -> Some (`RSA  , `SHA384)
  | SHA512_RSA    -> Some (`RSA  , `SHA512)
  | SHA224_RSA    -> Some (`RSA  , `SHA224)
  | ECDSA_SHA1    -> Some (`ECDSA, `SHA1)
  | ECDSA_SHA224  -> Some (`ECDSA, `SHA224)
  | ECDSA_SHA256  -> Some (`ECDSA, `SHA256)
  | ECDSA_SHA384  -> Some (`ECDSA, `SHA384)
  | ECDSA_SHA512  -> Some (`ECDSA, `SHA512)
  | _             -> None

and[@ocaml.warning "-8"] of_signature_algorithm public_key_algorithm digest =
  match public_key_algorithm, digest with
  | (`RSA  , `MD5)    -> MD5_RSA
  | (`RSA  , `SHA1)   -> SHA1_RSA
  | (`RSA  , `SHA256) -> SHA256_RSA
  | (`RSA  , `SHA384) -> SHA384_RSA
  | (`RSA  , `SHA512) -> SHA512_RSA
  | (`RSA  , `SHA224) -> SHA224_RSA
  | (`ECDSA, `SHA1)   -> ECDSA_SHA1
  | (`ECDSA, `SHA224) -> ECDSA_SHA224
  | (`ECDSA, `SHA256) -> ECDSA_SHA256
  | (`ECDSA, `SHA384) -> ECDSA_SHA384
  | (`ECDSA, `SHA512) -> ECDSA_SHA512

(* XXX
 *
 * PKCS1/RFC5280 allows params to be `ANY', depending on the algorithm.  I don't
 * know of one that uses anything other than NULL and OID, however, so we accept
 * only that.
 *)

let identifier =
  let open Registry in

  let f =
    let none x = function
      | None -> x
      | _    -> parse_error "Algorithm: expected no parameters"
    and null x = function
      | Some (`C1 ()) -> x
      | _             -> parse_error "Algorithm: expected null parameters"
    and oid f = function
      | Some (`C2 id) -> f id
      | _             -> parse_error "Algorithm: expected parameter OID"
    and default oid = Asn.(S.parse_error "Unknown algorithm %a" OID.pp oid) in

    case_of_oid_f ~default [

      (ANSI_X9_62.ec_pub_key, oid (fun id -> EC_pub id)) ;

      (PKCS1.rsa_encryption          , null RSA          ) ;
      (PKCS1.md2_rsa_encryption      , null MD2_RSA      ) ;
      (PKCS1.md4_rsa_encryption      , null MD4_RSA      ) ;
      (PKCS1.md5_rsa_encryption      , null MD5_RSA      ) ;
      (PKCS1.ripemd160_rsa_encryption, null RIPEMD160_RSA) ;
      (PKCS1.sha1_rsa_encryption     , null SHA1_RSA     ) ;
      (PKCS1.sha256_rsa_encryption   , null SHA256_RSA   ) ;
      (PKCS1.sha384_rsa_encryption   , null SHA384_RSA   ) ;
      (PKCS1.sha512_rsa_encryption   , null SHA512_RSA   ) ;
      (PKCS1.sha224_rsa_encryption   , null SHA224_RSA   ) ;

      (ANSI_X9_62.ecdsa_sha1         , none ECDSA_SHA1   ) ;
      (ANSI_X9_62.ecdsa_sha224       , none ECDSA_SHA224 ) ;
      (ANSI_X9_62.ecdsa_sha256       , none ECDSA_SHA256 ) ;
      (ANSI_X9_62.ecdsa_sha384       , none ECDSA_SHA384 ) ;
      (ANSI_X9_62.ecdsa_sha512       , none ECDSA_SHA512 ) ;

      (md2                           , null MD2          ) ;
      (md4                           , null MD4          ) ;
      (md5                           , null MD5          ) ;
      (sha1                          , null SHA1         ) ;
      (sha256                        , null SHA256       ) ;
      (sha384                        , null SHA384       ) ;
      (sha512                        , null SHA512       ) ;
      (sha224                        , null SHA224       ) ;
      (sha512_224                    , null SHA512_224   ) ;
      (sha512_256                    , null SHA512_256   ) ]

  and g =
    let none    = None
    and null    = Some (`C1 ())
    and oid  id = Some (`C2 id) in
    function
    | EC_pub id     -> (ANSI_X9_62.ec_pub_key , oid id)

    | RSA           -> (PKCS1.rsa_encryption           , null)
    | MD2_RSA       -> (PKCS1.md2_rsa_encryption       , null)
    | MD4_RSA       -> (PKCS1.md4_rsa_encryption       , null)
    | MD5_RSA       -> (PKCS1.md5_rsa_encryption       , null)
    | RIPEMD160_RSA -> (PKCS1.ripemd160_rsa_encryption , null)
    | SHA1_RSA      -> (PKCS1.sha1_rsa_encryption      , null)
    | SHA256_RSA    -> (PKCS1.sha256_rsa_encryption    , null)
    | SHA384_RSA    -> (PKCS1.sha384_rsa_encryption    , null)
    | SHA512_RSA    -> (PKCS1.sha512_rsa_encryption    , null)
    | SHA224_RSA    -> (PKCS1.sha224_rsa_encryption    , null)

    | ECDSA_SHA1    -> (ANSI_X9_62.ecdsa_sha1          , none)
    | ECDSA_SHA224  -> (ANSI_X9_62.ecdsa_sha224        , none)
    | ECDSA_SHA256  -> (ANSI_X9_62.ecdsa_sha256        , none)
    | ECDSA_SHA384  -> (ANSI_X9_62.ecdsa_sha384        , none)
    | ECDSA_SHA512  -> (ANSI_X9_62.ecdsa_sha512        , none)

    | MD2           -> (md2                            , null)
    | MD4           -> (md4                            , null)
    | MD5           -> (md5                            , null)
    | SHA1          -> (sha1                           , null)
    | SHA256        -> (sha256                         , null)
    | SHA384        -> (sha384                         , null)
    | SHA512        -> (sha512                         , null)
    | SHA224        -> (sha224                         , null)
    | SHA512_224    -> (sha512_224                     , null)
    | SHA512_256    -> (sha512_256                     , null)
  in

  map f g @@
  sequence2
    (required ~label:"algorithm" oid)
    (optional ~label:"params" (choice2 null oid))
