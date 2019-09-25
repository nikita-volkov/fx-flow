module FxFlow
where

import FxFlow.Prelude
import qualified Fx


-- * Accessor
-------------------------

{-|
Block running a flow until an async exception gets raised or the actor system fails with an error.
-}
flow :: Spawner env err (Flow () ()) -> Accessor env (Either SomeAsyncException err) ()
flow = error "TODO"


-- * Spawner
-------------------------

{-|
Context for spawning of actors.
-}
data Spawner env err a

{-|
Spawn an actor.
-}
spawn :: (i -> Accessor env err o) -> Spawner env err (Flow i o)
spawn = error "TODO"


-- * Flow
-------------------------

{-|
Composable message flow.
Abstraction over the connection of actors.
-}
data Flow i o
