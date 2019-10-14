module FxFlow
(
  -- * Fx
  flow,
  -- * Spawner
  Spawner,
  act,
  react,
  -- * Flow
  Flow,
  streamList,
)
where

import FxFlow.Prelude
import Fx


-- * Fx
-------------------------

flow :: Spawner env err (Flow ()) -> Fx env err ()
flow (Spawner spawn) = do
  (Flow flow, (kill, waitingFuture)) <- runStateT spawn (pure (), pure ())
  runFx (flow kill (const (return ())))
  wait waitingFuture


-- * Spawner
-------------------------

newtype Spawner env err a = Spawner (StateT (Fx () Void (), Future err ()) (Fx env err) a)
  deriving (Functor, Applicative, Monad, MonadFail)

{-|
Spawn a streaming channel,
which does not rely on any input messages.
-}
act :: ListT (Fx env err) out -> Spawner env err (Flow out)
act listT = fmap (\ flow -> flow ()) (react (const listT))

{-|
Spawn an actor, which receives messages of type @inp@ and
produces a finite stream of messages of type @out@,
getting a handle on its message flow.
-}
react :: (inp -> ListT (Fx env err) out) -> Spawner env err (inp -> Flow out)
react inpToListT = Spawner $ StateT $ \ (collectedKiller, collectedWaiter) -> do

  regChan <- runTotalIO (newTBQueueIO 100)
  aliveVar <- runTotalIO (newTVarIO True)

  future <- let
    listenToChanges =
      join $ runSTM $
        (do
          alive <- readTVar aliveVar
          guard (not alive)
          return (return ())
        ) <|>
        (do
          (inp, stop, emit) <- readTBQueue regChan
          return $ let
            eliminateListT (ListT step) = do
              alive <- runTotalIO (atomically (readTVar aliveVar))
              if alive
                then do
                  stepResult <- step
                  case stepResult of
                    Just (out, nextListT) -> do
                      runFx (emit out)
                      eliminateListT nextListT
                    Nothing -> do
                      runFx stop
                      listenToChanges
                else runFx stop
            in eliminateListT (inpToListT inp)
        )
    in start listenToChanges

  let
    flow inp = Flow (\ stop emit -> runTotalIO (atomically (writeTBQueue regChan (inp, stop, emit))))
    newCollectedKiller = do
      collectedKiller
      runTotalIO (atomically (writeTVar aliveVar False))
    newCollectedWaiter = collectedWaiter *> future
    in return (flow, (newCollectedKiller, newCollectedWaiter))


-- * Flow
-------------------------

{-|
Actor communication network composition.
Specifies the message flow between them.

You can think of it as a channel.
-}
newtype Flow a = Flow (Fx () Void () -> (a -> Fx () Void ()) -> Fx () Void ())
  deriving (Functor)

instance Applicative Flow where
  pure a = Flow (\ stop emit -> emit a *> stop)
  (<*>) (Flow reg1) (Flow reg2) = Flow (\ stop emit -> reg1 stop (\ aToB -> reg2 stop (emit . aToB)))

instance Monad Flow where
  return = pure
  (>>=) (Flow reg1) k2 = Flow (\ stop emit -> reg1 stop (k2 >>> \ (Flow reg2) -> reg2 stop emit))

instance Alternative Flow where
  empty = Flow (\ stop _ -> stop)
  (<|>) (Flow reg1) (Flow reg2) = Flow (\ stop emit -> reg1 stop emit *> reg2 stop emit)

instance MonadPlus Flow where
  mzero = empty
  mplus = (<|>)

instance Semigroup (Flow a) where
  (<>) = (<|>)

instance Monoid (Flow a) where
  mempty = empty
  mappend = (<>)

streamList :: [a] -> Flow a
streamList list = Flow $ \ stop emit -> forM_ list emit *> stop

streamListT :: ListT (Fx () Void) out -> Flow out
streamListT listT = Flow $ \ stop emit -> let
  eliminate (ListT step) = do
    stepResult <- step
    case stepResult of
      Just (out, nextListT) -> do
        emit out
        eliminate nextListT
      Nothing -> stop
  in eliminate listT
