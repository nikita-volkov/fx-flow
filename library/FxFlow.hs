module FxFlow
(
  -- * Accessor
  flow,
  -- * Spawner
  Spawner,
  act,
  react,
  -- * Flow
  Flow,
)
where

import FxFlow.Prelude
import qualified Exceptionless as Eio
import qualified Fx
import qualified FxStreaming.Accessor as Accessor
import qualified FxStreaming.Producer as Producer


-- * Producer
-------------------------

flow :: (SomeException -> err) -> Spawner env err (Flow out) -> Producer env err out
flow excToErr (Spawner spawnerReader) = Producer $ \ emit -> do

  finishedVar <- liftEio (Eio.liftSafeIO (newTVarIO False))
  errVar <- liftEio (Eio.liftSafeIO newEmptyTMVarIO)

  let reportErr = atomically . void . tryPutTMVar errVar

  -- Spawn the flow workers:
  (Flow flow, (kill, block)) <- 
    Fx.use $ \ env -> bimap1 excToErr $
    liftIO (runStateT (runReaderT spawnerReader (env, excToErr, reportErr)) (pure (), pure ()))

  Fx.use $ \ env -> bimap1 excToErr $ liftIO $ flow $ \ out -> do
    res <- runExceptT (liftEio (Fx.provideAndAccess (pure env) (emit out)))
    case res of
      Right True -> return ()
      Right False -> atomically (writeTVar finishedVar True)
      Left err -> reportErr err

  (join . bimap1 excToErr . liftIO . atomically . asum)
    [
      do
        err <- readTMVar errVar
        return $ do
          bimap1 excToErr (liftIO (kill *> block))
          throwError err
      ,
      do
        finished <- readTVar finishedVar
        guard finished
        return (bimap1 excToErr (liftIO (kill *> block)))
    ]

  return True


-- * Spawner
-------------------------

newtype Spawner env err a = Spawner (ReaderT (env, SomeException -> err, err -> IO ()) (StateT (IO (), IO ()) IO) a)
  deriving (Functor, Applicative, Monad)

act :: Producer env err out -> Spawner env err (Flow out)
act producer = fmap (\ flow -> flow ()) (react (const producer))

react :: (inp -> Producer env err out) -> Spawner env err (inp -> Flow out)
react inpToProducer = Spawner $ ReaderT $ \ (env, excToErr, reportErr) -> StateT $ \ (kill, block) -> do

  regChan <- newTBQueueIO 100
  deathLockVar <- newEmptyMVar

  forkIO $ fix $ \ loop -> do
    reg <- atomically $ readTBQueue regChan
    case reg of
      Just (inp, emit) -> let
        Producer produce = inpToProducer inp
        in do
          producing <-
            runExceptT $ liftEio $ Fx.provideAndAccess (pure env) $ produce $ \ out ->
            bimap1 excToErr (liftIO (emit out $> True))
          case producing of
            Right _ -> loop
            Left err -> do
              reportErr err
              putMVar deathLockVar ()
      Nothing -> putMVar deathLockVar ()

  let
    flow inp = Flow (\ emit -> atomically (writeTBQueue regChan (Just (inp, emit))))
    newKill = kill *> atomically (writeTBQueue regChan Nothing)
    newBlock = block *> readMVar deathLockVar
    in return (flow, (newKill, newBlock))


-- * Flow
-------------------------

{-|
Actor communication network composition.
Specifies the message flow between them.
-}
newtype Flow a =
  {-|
  Action registering a callback.

  The idea is that the outer action is lightweight
  it deals with composition and message registration.
  The continuation action is lightweight aswell,
  it just gets executed on a different thread some time later on.
  -}
  Flow ((a -> IO ()) -> IO ())
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
