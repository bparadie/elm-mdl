module Material.Options.Internal exposing (..)

import Html exposing (Attribute)
import Html.Attributes
import Html.Events
import String
import Json.Decode as Json

import Dispatch
import Material.Msg as Material


{-| Internal type of properties. Do not use directly; use constructor functions
   in the Options module or `attribute` instead.
-}
type Property c m 
  = Class String
  | CSS (String, String)
  | Attribute (Html.Attribute m)
  | Internal (Html.Attribute m)
  | Many (List (Property c m))
  | Set (c -> c)
  | Listener String (Maybe (Html.Events.Options)) (Json.Decoder m)
  | Lift (List m -> m)
  | None


{-| We've seen examples of users inadverdently overriding event handlers / html
classes / css styling with this function, causing malfunctions in the library.
So we hide it away here.  
-}
attribute : Html.Attribute m -> Property c m 
attribute =
  Internal


{-| Contents of a `Property c m`.
-}
type alias Summary c m = 
  { classes : List String 
  , css : List (String, String)  
  , attrs : List (Attribute m)
  , internal : List (Attribute m)
  , dispatch : Dispatch.Config m
  , config : c
  }


{- `collect` and variants are called multiple times by nearly every use of
  any elm-mdl component. Carefully consider performance implications before
  modifying. In particular: 

  - Avoid closures. They are slow to create and cause subsequent GC.
  - Pre-compute where possible. 

  Earlier versions of `collect`, violating these rules, consumed ~20% of
  execution time for `Cards.view` and `Textfield.view`.
-}


collect1 : Property c m -> Summary c m -> Summary c m
collect1 option acc = 
  case option of 
    Class x -> { acc | classes = x :: acc.classes }
    CSS x -> { acc | css = x :: acc.css }
    Attribute x -> { acc | attrs = x :: acc.attrs }
    Internal x -> { acc | internal = x :: acc.internal }
    Many options -> List.foldl collect1 acc options
    Set g -> { acc | config = g acc.config }
    Listener event options decoder ->
      { acc | dispatch = Dispatch.add event options decoder acc.dispatch }
    Lift m ->
      { acc | dispatch = Dispatch.plug m acc.dispatch }
    None -> acc


recollect : Summary c m  -> List (Property c m) -> Summary c m
recollect = 
  List.foldl collect1 


{-| Flatten a `Property a` into  a `Summary a`. Operates as `fold`
over options; first two arguments are folding function and initial value. 
-}
collect : c -> List (Property c m) -> Summary c m
collect =
  Summary [] [] [] [] Dispatch.defaultConfig >> recollect


{-| Special-casing of collect for `Property c ()`. 
-}
collect1' : Property c m -> Summary () m -> Summary () m
collect1' options acc = 
  case options of 
    Class x -> { acc | classes = x :: acc.classes }
    CSS x -> { acc | css = x :: acc.css }
    Attribute x -> { acc | attrs = x :: acc.attrs }
    Internal x -> { acc | internal = x :: acc.internal }
    Listener event options decoder ->
      { acc | dispatch = Dispatch.add event options decoder acc.dispatch }
    Many options -> List.foldl collect1' acc options
    Lift m ->
      { acc | dispatch = Dispatch.plug m acc.dispatch }
    Set _ -> acc 
    None -> acc


collect' : List (Property c m) -> Summary () m 
collect' = 
  List.foldl collect1' (Summary [] [] [] [] Dispatch.defaultConfig ())


addAttributes : Summary c m -> List (Attribute m) -> List (Attribute m)
addAttributes summary attrs =
  {- Ordering here is important: First apply summary attributes. That way,
  internal classes and attributes override those provided by the user.
  -}
  summary.attrs
    ++ [ Html.Attributes.style summary.css
       , Html.Attributes.class (String.join " " summary.classes)
       ]
    ++ attrs
    ++ summary.internal
    ++ Dispatch.install summary.dispatch


{-| Apply a `Summary m`, extra properties, and optional attributes 
to a standard Html node. 
-}
apply : Summary c m -> (List (Attribute m) -> a) 
    -> List (Property c m) -> List (Attribute m) -> a
apply summary ctor options attrs = 
  ctor 
    (addAttributes 
      (recollect summary options) 
      attrs)


type alias Container c m = 
  { c | container : List (Property () m) }


type alias Input c m = 
  { c | input : List (Property () m) }  


{-| TODO
-}
applyContainer : 
    Summary (Container c m) m 
 -> (List (Attribute m) -> a) 
 -> List (Property () m)  
 -> a
applyContainer summary ctor options = 
  apply 
    { summary | attrs = [], internal = [], config = () } 
    ctor
    (Many summary.config.container :: options)
    []


{-| TODO
-}
applyInput : 
    Summary (Input c m) m 
 -> (List (Attribute m) -> a) 
 -> List (Property () m)  
 -> a
applyInput summary ctor options = 
  apply 
    { summary | classes = [], css = [], config = () } 
    ctor
    (Many summary.config.input :: options)
    []



cfg : (c -> c) -> Property c m
cfg = 
  Set


input : List (Property () m) -> Property { a | input : List (Property () m) } m
input =
  let
    set options c = { c | input = Many options :: c.input }
  in
    set >> Set


container : List (Property () m) -> Property { a | container : List (Property () m) } m
container = 
  let
    set options c = { c | container = Many options :: c.container }
  in
    set >> Set


dispatch : (Material.Msg a m -> m) -> Property c m
dispatch lift =
  Lift (Material.Dispatch >> lift)


{-| Inject dispatch
 -}
inject
    : (a -> b -> List (Property d e) -> f -> g)
    -> (Material.Msg h e -> e)
    -> a
    -> b
    -> List (Property d e)
    -> f
    -> g
inject view lift a b c =
  view a b (dispatch lift :: c)


{-| Construct lifted handler with trivial decoder in a manner that
virtualdom will like. 

vdom diffing will recognise two different executions of the following to be
identical: 

    Json.map lift <| Json.succeed m    -- (a)

vdom diffing will _not_ recognise two different executions of this seemingly
simpler variant to be identical:

    Json.succeed (lift m)              -- (b)

In the common case, both `lift` and `m` will be a top-level constructors, say
`Mdl` and `Click`. In this case, the `lift m` in (b) is constructed anew on
each `view`, and vdom can't tell that the argument to Json.succeed is the same.
In (a), though, we're constructing no new values besides a Json decoder, which
will be taken apart as part of vdoms equality check; vdom _can_ in this case
tell that the previous and current decoder is the same. 

See #221 / this thread on elm-discuss:
https://groups.google.com/forum/#!topic/elm-discuss/Q6mTrF4T7EU
-}
on1 : String -> (a -> b) -> a -> Property c b
on1 event lift m = 
  Listener event Nothing (Json.map lift <| Json.succeed m)

