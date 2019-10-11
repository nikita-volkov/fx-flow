module FxFlow
(
  -- * Fx
  flowForever,
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

flowForever :: Spawner env err (Flow a) -> Fx env err Void
flowForever (Spawner m) = do
  (kill, waitingFuture) <- execStateT m (pure (), pure ())
  wait waitingFuture
  fail "Unexpectedly the flow has reached finish"


-- * Spawner
-------------------------

newtype Spawner env err a = Spawner (StateT (Fx env err (), Future env err ()) (Fx env err) a)
  deriving (Functor, Applicative, Monad)

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

  future <- start $ fix $ \ processNextMessage -> do
    msg <- runTotalIO $ atomically $ readTBQueue regChan
    case msg of
      Just (inp, emit) -> let
        eliminateListT (ListT step) = do
          stepResult <- step
          case stepResult of
            Just (out, nextListT) -> do
              mapEnv (const ()) (bimap1 absurd (emit out))
              eliminateListT nextListT
            Nothing -> processNextMessage
        in eliminateListT (inpToListT inp)
      Nothing -> return ()

  let
    flow inp = Flow (\ emit -> runTotalIO (atomically (writeTBQueue regChan (Just (inp, emit)))))
    newCollectedKiller = do
      collectedKiller
      runTotalIO (atomically (writeTBQueue regChan Nothing))
    newCollectedWaiter = do
      collectedWaiter
      future
    in return (flow, (newCollectedKiller, newCollectedWaiter))


-- * Flow
-------------------------

{-|
Actor communication network composition.
Specifies the message flow between them.
-}
newtype Flow a = Flow ((a -> Fx () Void ()) -> Fx () Void ())
  deriving (Functor)

instance Applicative Flow where
  pure a = Flow (\ emit -> emit a)
  (<*>) (Flow reg1) (Flow reg2) = Flow (\ emit -> reg1 (\ aToB -> reg2 (emit . aToB)))

instance Monad Flow where
  return = pure
  (>>=) (Flow reg1) k2 = Flow $ \ emit -> reg1 $ k2 >>> \ (Flow reg2) -> reg2 emit

instance Alternative Flow where
  empty = Flow (\ emit -> return ())
  (<|>) (Flow reg1) (Flow reg2) = Flow $ \ emit -> reg1 emit *> reg2 emit

instance MonadPlus Flow where
  mzero = empty
  mplus = (<|>)

instance Semigroup (Flow a) where
  (<>) = (<|>)

instance Monoid (Flow a) where
  mempty = empty
  mappend = (<>)

streamList :: [a] -> Flow a
streamList list = Flow $ \ emit -> forM_ list emit
