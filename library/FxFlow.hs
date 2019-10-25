module FxFlow
(
  -- * Fx
  flow,
  -- * Spawner
  Spawner,
  react,
  ditchInput,
  distribute,
  -- * Flow
  Flow,
  streamList,
)
where

import FxFlow.Prelude
import Fx
import qualified Data.Vector as Vector


-- * Fx
-------------------------

flow :: Spawner env err (Flow ()) -> Fx env err (Future err ())
flow (Spawner spawn) = do
  (Flow flow, (kill, waitingFuture)) <- runStateT spawn (pure (), pure ())
  runSTM (flow kill (const (return ())))
  return waitingFuture


-- * Spawner
-------------------------

newtype Spawner env err a = Spawner (StateT (STM (), Future err ()) (Fx env err) a)
  deriving (Functor, Applicative, Monad, MonadFail)

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
              alive <- runSTM (readTVar aliveVar)
              if alive
                then do
                  stepResult <- step
                  case stepResult of
                    Just (out, nextListT) -> do
                      runSTM (emit out)
                      eliminateListT nextListT
                    Nothing -> do
                      runSTM stop
                      listenToChanges
                else runSTM stop
            in eliminateListT (inpToListT inp)
        )
    in start listenToChanges

  let
    flow inp = Flow (\ stop emit -> writeTBQueue regChan (inp, stop, emit))
    newCollectedKiller = do
      collectedKiller
      writeTVar aliveVar False
    newCollectedWaiter = collectedWaiter *> future
    in return (flow, (newCollectedKiller, newCollectedWaiter))

ditchInput :: Spawner env err (() -> Flow a) -> Spawner env err (Flow a)
ditchInput = fmap (\ flow -> flow ())

distribute :: [Spawner env err (a -> Flow b)] -> Spawner env err (a -> Flow b)
distribute spawnerList = if null spawnerList
  then return $ const empty
  else do
    indexVar <- Spawner $ lift $ runSTM $ newTVar 0
    flowFnVec <- sequence $ Vector.fromList spawnerList
    return $ \ inp -> Flow $ \ stop emit -> do
      index <- readTVar indexVar
      case flowFnVec Vector.!? index of
        Just flowFn -> do
          writeTVar indexVar $! succ index
          case flowFn inp of Flow flowImp -> flowImp stop emit
        _ -> do
          writeTVar indexVar 1
          case Vector.unsafeIndex flowFnVec 0 inp of Flow flowImp -> flowImp stop emit


-- * Flow
-------------------------

{-|
Actor communication network composition.
Specifies the message flow between them.

You can think of it as a channel.
-}
newtype Flow a = Flow (STM () -> (a -> STM ()) -> STM ())
  deriving (Functor)

instance Applicative Flow where
  pure a = Flow (\ stop emit -> emit a *> stop)
  (<*>) (Flow reg1) (Flow reg2) = Flow $ \ stop emit -> do
    stoppedVar1 <- newTVar False
    stoppedVar2 <- newTVar False
    let
      stop1 = do
        stopped2 <- readTVar stoppedVar2
        if stopped2
          then stop
          else writeTVar stoppedVar1 True
      stop2 = do
        stopped1 <- readTVar stoppedVar1
        if stopped1
          then stop
          else writeTVar stoppedVar2 True
      in reg1 stop1 (\ aToB -> reg2 stop2 (emit . aToB))

instance Monad Flow where
  return = pure
  (>>=) (Flow reg1) k2 = Flow $ \ stop emit -> do
    unregisteredVar <- newTVar False
    let
      stop1 = writeTVar unregisteredVar True
      emit1 a = case k2 a of
        Flow reg2 -> reg2 stop2 emit
      stop2 = do
        unregistered <- readTVar unregisteredVar
        if unregistered
          then stop
          else return ()
      in reg1 stop1 emit1

instance Alternative Flow where
  empty = Flow (\ stop _ -> stop)
  (<|>) (Flow reg1) (Flow reg2) = Flow $ \ stop emit -> do
    stoppedVar1 <- newTVar False
    stoppedVar2 <- newTVar False
    let
      stop1 = do
        stopped2 <- readTVar stoppedVar2
        if stopped2
          then stop
          else writeTVar stoppedVar1 True
      stop2 = do
        stopped1 <- readTVar stoppedVar1
        if stopped1
          then stop
          else writeTVar stoppedVar2 True
      in reg1 stop1 emit *> reg2 stop2 emit

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
